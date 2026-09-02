import IOBluetooth
import Foundation
import ObjectiveC

// Reads battery level from Bluetooth Classic headphones via private IOBluetoothDevice methods.
// headsetBattery — level received via HFP +IPHONEACCEV / +XAPLEACC.
// batteryPercentSingle — fallback for single-cell BT devices.
class BTHeadphonesReader: NSObject {
    var onUpdate: (([AccessoryBattery]) -> Void)?

    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [IOBluetoothUserNotification] = []
    private var timer: Timer?

    func startMonitoring() {
        connectNote = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
        read()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.read()
        }
    }

    func readOnce() { read() }

    private func read() {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        var result: [AccessoryBattery] = []
        for device in devices {
            guard device.isConnected(), let name = device.name else { continue }
            let lower = name.lowercased()
            guard !lower.contains("airpod") else { continue }
            guard !lower.contains("keyboard"), !lower.contains("mouse"), !lower.contains("trackpad") else { continue }
            guard let level = privateBatteryLevel(device), level > 0, level <= 100 else { continue }
            result.append(AccessoryBattery(name: name, level: level, charging: false))
        }
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(result) }
    }

    // Calls private IOBluetoothDevice selectors that return an int battery level.
    private func privateBatteryLevel(_ device: IOBluetoothDevice) -> Int? {
        for name in ["headsetBattery", "batteryPercentSingle", "batteryPercentCombined"] {
            let sel = NSSelectorFromString(name)
            guard device.responds(to: sel) else { continue }
            if let v = callIntSelector(device, sel), v > 0, v <= 100 { return v }
        }
        return nil
    }

    private func callIntSelector(_ obj: AnyObject, _ sel: Selector) -> Int? {
        guard let imp = class_getMethodImplementation(type(of: obj) as! AnyClass, sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Int32
        return Int(unsafeBitCast(imp, to: Fn.self)(obj, sel))
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.read() }
        if let n = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:))) {
            disconnectNotes.append(n)
        }
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        read()
    }
}
