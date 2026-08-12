import CoreBluetooth
import Foundation

// Reads battery level from BLE peripherals via GATT Battery Service (UUID 0x180F).
// Works for any BLE device that exposes Battery Level (0x2A19) and is visible to
// CoreBluetooth (i.e. not exclusively managed by IOKit HID kernel driver).
// Note: BLE HID mice/keyboards (e.g. Logitech MX series) are IOKit-only and
// are NOT accessible via this path without privileged entitlements.
class BLEDeviceReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onUpdate: (([AccessoryBattery]) -> Void)?

    private var central: CBCentralManager?
    private var peripherals:     [UUID: CBPeripheral]           = [:]
    private var battChars:       [UUID: CBCharacteristic]       = [:]
    private var levels:          [UUID: Int]                    = [:]
    private var names:           [UUID: String]                 = [:]
    private var previousLevels:  [UUID: Int]                    = [:]
    private var chargingStates:  [UUID: Bool]                   = [:]

    private static let battService  = CBUUID(string: "180F")
    private static let battCharUUID = CBUUID(string: "2A19")

    // Service UUIDs to query for already-connected peripherals.
    // 180A (Device Information) is intentionally excluded — it's too generic and matches
    // phones, tablets, and other devices we don't want to show as accessories.
    // Note: macOS gives IOKit exclusive access to 1812 (HID) on BLE input devices, so
    // CoreBluetooth can only find them via 180F (Battery Service).
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
                peripherals[p.identifier] = p
                names[p.identifier] = p.name ?? "Unknown Device"
                p.delegate = self
                central.connect(p, options: nil)
            }
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([Self.battService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        peripherals.removeValue(forKey: p.identifier)
        names.removeValue(forKey: p.identifier)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        levels.removeValue(forKey: p.identifier)
        battChars.removeValue(forKey: p.identifier)
        previousLevels.removeValue(forKey: p.identifier)
        chargingStates.removeValue(forKey: p.identifier)
        peripherals.removeValue(forKey: p.identifier)
        names.removeValue(forKey: p.identifier)
        publish()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == Self.battService }) else { return }
        p.discoverCharacteristics([Self.battCharUUID], for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        guard let ch = svc.characteristics?.first(where: { $0.uuid == Self.battCharUUID }) else { return }
        battChars[p.identifier] = ch
        p.readValue(for: ch)
        if ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
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

    private func publish() {
        let items = peripherals.values.compactMap { p -> AccessoryBattery? in
            guard let level = levels[p.identifier],
                  let name  = names[p.identifier]
            else { return nil }
            let charging = chargingStates[p.identifier] ?? false
            return AccessoryBattery(name: name, level: level, charging: charging)
        }.sorted { $0.name < $1.name }
        onUpdate?(items)
    }
}
