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
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var levels:      [UUID: Int]          = [:]
    private var names:       [UUID: String]       = [:]

    private static let battService  = CBUUID(string: "180F")
    private static let battCharUUID = CBUUID(string: "2A19")

    // Service UUIDs to query for already-connected peripherals. Battery Service first;
    // HID Service included so we discover any BLE HID device that CoreBluetooth can see.
    private static let probedServices: [CBUUID] = [
        CBUUID(string: "180F"),  // Battery Service
        CBUUID(string: "1812"),  // HID
        CBUUID(string: "180A"),  // Device Information
    ]

    func startMonitoring() {
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func refresh() {
        guard central?.state == .poweredOn else { return }
        connectExisting()
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
        p.readValue(for: ch)
        if ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == Self.battCharUUID, let level = ch.value?.first else { return }
        levels[p.identifier] = Int(level)
        publish()
    }

    private func publish() {
        let items = peripherals.values.compactMap { p -> AccessoryBattery? in
            guard let level = levels[p.identifier],
                  let name  = names[p.identifier]
            else { return nil }
            return AccessoryBattery(name: name, level: level, charging: false)
        }.sorted { $0.name < $1.name }
        onUpdate?(items)
    }
}
