import CoreBluetooth
import Foundation
import IOBluetooth
import ObjectiveC

struct AirPodsBattery {
    let left:  Int?   // 0-100, nil = not visible (in case / unavailable)
    let right: Int?
    let `case`: Int?
    let leftCharging:  Bool
    let rightCharging: Bool
    let caseCharging:  Bool

    func isEqual(to other: AirPodsBattery?) -> Bool {
        guard let other else { return false }
        return left == other.left && right == other.right && self.case == other.case
            && leftCharging == other.leftCharging && rightCharging == other.rightCharging
            && caseCharging == other.caseCharging
    }
}

// Reads AirPods battery via BLE Proximity Pairing advertisements (Apple proprietary).
//
// Case visibility rule (derived from charging-bits field):
//   chargingBits == 0xF  →  case not connected (pods in ears)  →  show pods, hide case
//   chargingBits != 0xF  →  case connected (pods in case)      →  show case, hide pods
//
// Disappear rule: if no advertisement is received for 10 s (closed case stops broadcasting
// aggressively once the host is no longer looking for new devices), hide the row.
//
// Battery levels: plist written by audioaccessoryd (1 % precision) with BLE nibbles as fallback.
class AirPodsReader: NSObject, CBCentralManagerDelegate {
    var onUpdate: ((AirPodsBattery?) -> Void)?
    var onConnect: ((String) -> Void)?

    private var central: CBCentralManager?
    private var hideTimer: Timer?
    private var syncTimer: Timer?
    private var plistLevels: PlistLevels?
    private var lastBattery: AirPodsBattery?

    // Cached selectors for framework parsing
    private let selAlloc    = NSSelectorFromString("alloc")
    private let selInitData = NSSelectorFromString("initWithData:")
    private let selPayloads = NSSelectorFromString("payloads")
    private var advClass: NSObject.Type?

    private struct PlistLevels {
        let left: Int?
        let right: Int?
        let cas: Int?
    }

    func startMonitoring() {
        dlopen("/System/Library/PrivateFrameworks/AudioAccessoryServices.framework/AudioAccessoryServices", RTLD_NOW)
        advClass = NSClassFromString("AAManufacturerDataAdvertisement") as? NSObject.Type
        refreshPlist()
        watchPlist()
        central = CBCentralManager(delegate: self, queue: .main)
        IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(bluetoothDeviceConnected(_:device:)))
        if let device = btDevice(), device.isConnected() {
            device.register(forDisconnectNotification: self, selector: #selector(bluetoothDeviceDisconnected(_:device:)))
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            self?.refreshPlist()
            if let battery = self?.lastBattery {
                self?.onUpdate?(battery)
            }
        }
    }

    @objc private func bluetoothDeviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let name = device.name, name.lowercased().contains("airpod") else { return }
        device.register(forDisconnectNotification: self, selector: #selector(bluetoothDeviceDisconnected(_:device:)))
        DispatchQueue.main.async { [weak self] in
            self?.onConnect?(name)
            self?.refreshPlist()
        }
    }

    @objc private func bluetoothDeviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        hideTimer?.invalidate()
        lastBattery = nil
        onUpdate?(nil)
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard RSSI.intValue > -70 else { return }

        guard let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              mfr.count >= 10,
              mfr[0] == 0x4C, mfr[1] == 0x00,
              mfr[2] == 0x07
        else { return }

        // Check lid state off the main thread to avoid retain issues with the framework.
        // The result arrives on main and gates whether we proceed.
        let mfrCopy = mfr
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let lidClosed = self?.isLidClosed(mfrCopy) ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if lidClosed {
                    // Lid is shut: pods not in use, hide the row and arm the timer
                    // so it hides even if lid is opened slowly while still in range
                    self.resetHideTimer()
                    self.onUpdate?(nil)
                    return
                }
                self.handleAdvertisement(mfrCopy)
            }
        }
    }

    private func handleAdvertisement(_ mfr: Data) {
        guard isConnected else { return }
        resetHideTimer()
        refreshPlist()

        let status       = mfr[7]
        let flip         = (status & 0x20) != 0
        let pods         = mfr[8]
        let caseData     = mfr[9]

        let podHi        = Int((pods >> 4) & 0x0F)
        let podLo        = Int(pods & 0x0F)
        let caseV        = Int((caseData >> 4) & 0x0F)
        let chargingBits = Int(caseData & 0x0F)

        let leftRaw  = flip ? podHi : podLo
        let rightRaw = flip ? podLo : podHi

        // chargingBits == 0xF → case not connected → pods are in ears
        let inCase = chargingBits != 0xF

        let leftBat:  Int?
        let rightBat: Int?
        let caseBat:  Int?

        // When inCase: show pods + case; when in ears: show pods only, hide case
        leftBat  = plistLevels?.left  ?? (leftRaw  < 0xF ? min(leftRaw  * 10, 100) : nil)
        rightBat = plistLevels?.right ?? (rightRaw < 0xF ? min(rightRaw * 10, 100) : nil)
        caseBat  = inCase ? (plistLevels?.cas ?? (caseV < 0xF ? min(caseV * 10, 100) : nil)) : nil

        guard leftBat != nil || rightBat != nil || caseBat != nil else { return }

        let validCharging = chargingBits < 0xF
        // flip alternates between packets as the primary pod switches, making per-pod
        // charging bits jump L↔R. Both pods charge together in the case anyway,
        // so show charging on both whenever either pod-charging bit is set.
        let anyPodCharging = validCharging && (chargingBits & 0x03) != 0
        let leftCharging  = anyPodCharging
        let rightCharging = anyPodCharging
        let caseCharging  = false

        let battery = AirPodsBattery(
            left: leftBat, right: rightBat, case: caseBat,
            leftCharging: leftCharging, rightCharging: rightCharging, caseCharging: caseCharging
        )
        guard !battery.isEqual(to: lastBattery) else { return }
        lastBattery = battery
        onUpdate?(battery)
    }

    // MARK: - Lid closed detection

    // Called on a background thread to avoid retain-cycle crash in BLE callback.
    // Uses alloc+init split with correct ownership: alloc is unretained (init consumes it).
    private func isLidClosed(_ mfr: Data) -> Bool {
        guard let cls = advClass else { return false }
        // takeUnretainedValue on alloc: init will consume the +1, so we must not take it here
        guard let obj = cls.perform(selAlloc)?.takeUnretainedValue() as? NSObject else { return false }
        guard let adv = obj.perform(selInitData, with: mfr as NSData)?.takeRetainedValue() as? NSObject else { return false }
        guard let payloads = adv.perform(selPayloads)?.takeUnretainedValue() as? [AnyObject],
              let payload = payloads.first else { return false }
        return (payload as AnyObject).value(forKey: "lidClosed") as? Int == 1
    }

    // MARK: - Hide timer

    private func resetHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            self?.onUpdate?(nil)
        }
    }

    // MARK: - Plist (high-precision battery from audioaccessoryd)

    private let prefPath = NSHomeDirectory() + "/Library/Preferences/com.apple.AudioAccessory.plist"
    private var fileWatcher: DispatchSourceFileSystemObject?

    private func watchPlist() {
        let fd = open(prefPath, O_RDONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.refreshPlist() }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileWatcher = src
    }

    private func refreshPlist() {
        guard let prefs = NSDictionary(contentsOfFile: prefPath),
              let data = prefs["lastSeenBatteryInfosV2"] as? Data,
              let u = try? NSKeyedUnarchiver(forReadingFrom: data)
        else { plistLevels = nil; return }

        u.requiresSecureCoding = false
        guard let dict = u.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSDictionary
        else { plistLevels = nil; return }

        for (_, v) in dict {
            let info = v as AnyObject
            plistLevels = PlistLevels(
                left:  plistLevel(info, sel: "batteryLeft"),
                right: plistLevel(info, sel: "batteryRight"),
                cas:   plistLevel(info, sel: "batteryCase")
            )
            return
        }
        plistLevels = nil
    }

    private func plistLevel(_ info: AnyObject, sel: String) -> Int? {
        let s = NSSelectorFromString(sel)
        guard info.responds(to: s),
              let bat = info.perform(s)?.takeUnretainedValue() as AnyObject?,
              let lvl = bat.value(forKey: "level") as? Double,
              lvl > 0
        else { return nil }
        return Int(round(lvl * 100)).clamped(to: 1...100)
    }

    // MARK: - Bluetooth connect / disconnect

    var isConnected:  Bool    { btDevice()?.isConnected() ?? false }
    var deviceName:   String? { btDevice()?.name }

    func connect()    { btDevice()?.openConnection()  }
    func disconnect() { btDevice()?.closeConnection() }

    private func btDevice() -> IOBluetoothDevice? {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first {
            $0.name?.lowercased().contains("airpod") == true
        }
    }
}

private extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self {
        min(max(self, r.lowerBound), r.upperBound)
    }
}
