import Foundation
import IOKit
import IOBluetooth

struct AccessoryBattery {
    let name: String
    let level: Int
    let charging: Bool
    var isApple: Bool = false

    private var isKeyboard: Bool {
        let lower = name.lowercased()
        return lower.contains("keyboard") || lower.contains(" keys") || lower.contains("k380")
            || lower.contains("k780") || lower.contains("k800") || lower.contains("k850")
    }

    private var isHeadphones: Bool {
        let lower = name.lowercased()
        return lower.contains("bud") || lower.contains("headphone") || lower.contains("earphone")
    }

    var icon: String {
        let lower = name.lowercased()
        if isHeadphones               { return "headphones" }
        if isKeyboard                 { return "keyboard" }
        if lower.contains("trackpad") { return "trackpad" }
        return isApple ? "magicmouse" : "computermouse"
    }

    var iconChar: String? {
        name.lowercased().contains("trackpad") ? "􀏃" : nil
    }

    var batteryDevice: BatteryDevice {
        let lower = name.lowercased()
        if isHeadphones               { return .headphones }
        if isKeyboard                 { return .keyboard }
        if lower.contains("trackpad") { return .trackpad }
        return .mouse
    }
}

class AccessoryReader: NSObject {
    var onUpdate: (([AccessoryBattery]) -> Void)?
    private var timer: Timer?
    private var disconnectNotifications: [IOBluetoothUserNotification] = []
    private var connectNotification: IOBluetoothUserNotification?

    func startMonitoring() {
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
        read()
        // Poll every 5 s for the first minute (BT may not be ready at login), then every 60 s.
        var ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
            self?.read()
            ticks += 1
            if ticks >= 12 {
                t.invalidate()
                self?.timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
                    self?.read()
                }
            }
        }
    }

    func readOnce() { read() }

    private func read() {
        readReturningFound(addr: "")
    }

    private func registerDisconnectNotifications() {
        disconnectNotifications.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        for device in paired {
            guard device.isConnected() else { continue }
            let name = (device.name ?? "").lowercased()
            guard name.contains("keyboard") || name.contains("mouse") || name.contains("trackpad") else { continue }
            if let note = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:))) {
                disconnectNotifications.append(note)
            }
        }
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // IOKit HID service appears asynchronously after BT connects — retry until found.
        let addr = device.addressString?.lowercased() ?? ""
        retryUntilFound(addr: addr, attempts: 10, interval: 0.5)
    }

    private func retryUntilFound(addr: String, attempts: Int, interval: TimeInterval) {
        if readReturningFound(addr: addr) || attempts <= 1 { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.retryUntilFound(addr: addr, attempts: attempts - 1, interval: interval)
        }
    }

    // Returns true if the device with the given BT address appeared in IOKit.
    @discardableResult
    private func readReturningFound(addr: String) -> Bool {
        var btNames: [String: String] = [:]
        if let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for d in devices {
                if let a = d.addressString, let name = d.name {
                    btNames[a.lowercased()] = name
                }
            }
        }

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
            &iter
        ) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iter) }

        var seen: [String: AccessoryBattery] = [:]
        var found = false
        var service = IOIteratorNext(iter)
        while service != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iter)
            }
            var cfProps: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &cfProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = cfProps?.takeRetainedValue() as? [String: Any],
                  let battery = props["BatteryPercent"] as? Int, battery > 0,
                  let product = props["Product"] as? String, !product.isEmpty
            else { continue }

            // Skip Logitech devices — handled by LogitechReader with better data.
            let vendorID = props["VendorID"] as? Int ?? 0
            guard vendorID != 0x046D else { continue }

            let lower = product.lowercased()
            guard lower.contains("keyboard") || lower.contains("mouse") || lower.contains("trackpad")
            else { continue }

            if seen[product] == nil {
                let devAddr = (props["DeviceAddress"] as? String)?.lowercased() ?? ""
                let displayName = btNames[devAddr] ?? product
                let flags = props["BatteryStatusFlags"] as? Int ?? 0
                let charging = (flags & 2) != 0
                seen[product] = AccessoryBattery(name: displayName, level: battery, charging: charging, isApple: true)
                if !addr.isEmpty && devAddr == addr { found = true }
            }
        }

        let result = Array(seen.values).sorted { $0.name < $1.name }
        registerDisconnectNotifications()
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(result)
        }
        return found
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        read()
    }
}
