import CoreBluetooth
import Foundation

// Reads battery level from BLE peripherals via GATT Battery Service (UUID 0x180F).
// Works for any BLE device that exposes Battery Level (0x2A19) and is visible to
// CoreBluetooth (i.e. not exclusively managed by IOKit HID kernel driver).
// Logitech devices are filtered by reading PnP ID (0x2A50) from Device Information
// Service (0x180A) and checking VendorID == 0x046D; they are handled by LogitechReader.
class BLEDeviceReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onUpdate: (([AccessoryBattery]) -> Void)?

    private var central: CBCentralManager?
    private var peripherals:     [UUID: CBPeripheral]   = [:]
    private var battChars:       [UUID: CBCharacteristic] = [:]
    private var levels:          [UUID: Int]            = [:]
    private var previousLevels:  [UUID: Int]            = [:]
    private var chargingStates:  [UUID: Bool]           = [:]
    // Peripherals confirmed as Logitech via PnP ID — permanently excluded.
    private var logiPeripherals: Set<UUID>              = []

    private static let battService   = CBUUID(string: "180F")
    private static let battCharUUID  = CBUUID(string: "2A19")
    private static let devInfoService = CBUUID(string: "180A")
    private static let pnpIDCharUUID  = CBUUID(string: "2A50")

    // Service UUIDs to query for already-connected peripherals.
    // 180A (Device Information) is intentionally excluded from probing — it's too generic
    // and matches phones, tablets, and other devices we don't want to show as accessories.
    private static let probedServices: [CBUUID] = [
        CBUUID(string: "180F"),  // Battery Service
        CBUUID(string: "1812"),  // HID
    ]

    func startMonitoring() {
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func refresh() {
        guard central?.state == .poweredOn else { return }
        connectExisting()
        for (id, ch) in battChars {
            peripherals[id]?.readValue(for: ch)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        connectExisting()
    }

    private func connectExisting() {
        guard let central else { return }
        var seen = Set<UUID>()
        for svc in Self.probedServices {
            for p in central.retrieveConnectedPeripherals(withServices: [svc]) {
                guard seen.insert(p.identifier).inserted else { continue }
                guard peripherals[p.identifier] == nil else { continue }
                guard !logiPeripherals.contains(p.identifier) else { continue }
                // iPhones and iPads are handled by IDeviceReader; skip them here.
                let lower = (p.name ?? "").lowercased()
                guard !lower.contains("iphone"), !lower.contains("ipad") else { continue }
                peripherals[p.identifier] = p
                p.delegate = self
                central.connect(p, options: nil)
            }
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        // Discover Battery Service to read level, and Device Information Service to check VendorID.
        p.discoverServices([Self.battService, Self.devInfoService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        remove(p.identifier)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        remove(p.identifier)
        publish()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for svc in p.services ?? [] {
            switch svc.uuid {
            case Self.battService:
                p.discoverCharacteristics([Self.battCharUUID], for: svc)
            case Self.devInfoService:
                p.discoverCharacteristics([Self.pnpIDCharUUID], for: svc)
            default:
                break
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        if svc.uuid == Self.battService,
           let ch = svc.characteristics?.first(where: { $0.uuid == Self.battCharUUID }) {
            battChars[p.identifier] = ch
            p.readValue(for: ch)
            if ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) }
        } else if svc.uuid == Self.devInfoService,
                  let ch = svc.characteristics?.first(where: { $0.uuid == Self.pnpIDCharUUID }) {
            p.readValue(for: ch)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if ch.uuid == Self.pnpIDCharUUID {
            // PnP ID layout: [vendorIDSource(1), vendorID(2 LE), productID(2), productVersion(2)]
            if let data = ch.value, data.count >= 3 {
                let vendorID = UInt16(data[1]) | (UInt16(data[2]) << 8)
                if vendorID == 0x046D {  // Logitech — handled by LogitechReader via HID++ 2.0
                    logiPeripherals.insert(p.identifier)
                    remove(p.identifier)
                    publish()
                }
            }
            return
        }

        guard ch.uuid == Self.battCharUUID, let raw = ch.value?.first else { return }
        let newLevel = Int(raw)
        let id = p.identifier
        // Reject obviously invalid readings: below 5% (device would disconnect before reaching
        // this level in practice) or an impossible sudden drop of >50 points in one reading.
        guard newLevel >= 5 else { return }
        if let prev = previousLevels[id], newLevel < prev - 50 { return }
        // Infer charging from trend: if level rose since the last reading, the device is charging.
        if let prev = previousLevels[id] {
            if newLevel > prev      { chargingStates[id] = true  }
            else if newLevel < prev { chargingStates[id] = false }
        }
        previousLevels[id] = newLevel
        levels[id] = newLevel
        publish()
    }

    private func remove(_ id: UUID) {
        peripherals.removeValue(forKey: id)
        battChars.removeValue(forKey: id)
        levels.removeValue(forKey: id)
        previousLevels.removeValue(forKey: id)
        chargingStates.removeValue(forKey: id)
    }

    private func publish() {
        let items = peripherals.values.compactMap { p -> AccessoryBattery? in
            guard let level = levels[p.identifier] else { return nil }
            let name = p.name ?? "Unknown Device"
            let charging = chargingStates[p.identifier] ?? false
            return AccessoryBattery(name: name, level: level, charging: charging)
        }.sorted { $0.name < $1.name }
        onUpdate?(items)
    }
}
