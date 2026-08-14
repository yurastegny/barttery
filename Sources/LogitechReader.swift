import AppKit
import Foundation
import IOKit
import IOKit.hid

// Reads battery level and charging state from Logitech MX mice via HID++ 2.0.
// Uses IOKit in shared (non-exclusive) mode with Input Monitoring permission.
// If permission is not granted the reader returns no results and BLEDeviceReader
// serves as a fallback (discrete levels, trend-based charging).
// Protocol modeled on https://github.com/pcolman/mx-battery (MIT).
class LogitechReader {
    var onUpdate: (([AccessoryBattery]) -> Void)?
    /// Called immediately after IOKit enumeration, before battery queries complete.
    /// Provides the set of device names currently visible via HID++ so callers can
    /// reserve those names and prevent other readers from racing in.
    var onDevicesFound: ((Set<String>) -> Void)?
    private var timer: Timer?
    private var lastKnownLevels: [String: Int] = [:]

    private static let supportedPIDs: [Int: String] = [
        // MX Master
        0xB019: "MX Master 2S",
        0xB021: "MX Master 3 for Mac",
        0xB023: "MX Master 3",
        0xB034: "MX Master 3S",
        0xB02F: "MX Master 3S for Mac",
        0xB037: "MX Master 4",
        // MX Anywhere
        0xB013: "MX Anywhere 2S",
        0xB025: "MX Anywhere 3",
        0xB028: "MX Anywhere 3 for Mac",
        0xB03D: "MX Anywhere 3S",
        // Other MX mice
        0xB00E: "MX Ergo",
        0xB010: "M720 Triathlon",
        0xB018: "MX Vertical",
        // MX Keys keyboards
        0xB35B: "MX Keys",
        0xB35C: "MX Keys for Mac",
        0xB361: "MX Keys Mini",
        0xB369: "MX Keys Mini for Mac",
        0xB366: "MX Keys S",
        // Compact Bluetooth keyboards
        0xB342: "K380 Keyboard",
        0xB35D: "K780 Keyboard",
        0xB350: "K850 Keyboard",
    ]

    private static let skippedKey = "logitech.inputMonitoring.skipped"

    func startMonitoring() {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if access == kIOHIDAccessTypeUnknown,
           !UserDefaults.standard.bool(forKey: Self.skippedKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.requestPermissionWithExplanation()
            }
        }
        readDevices()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.readDevices()
        }
    }

    private func requestPermissionWithExplanation() {
        let alert = NSAlert()
        alert.messageText = "Logitech Device Battery"
        alert.informativeText = "To monitor the battery level and charging status of Logitech devices, Input Monitoring permission is required. Skip this if you don't have any Logitech devices."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Skip")
        alert.alertStyle = .informational
        if alert.runModal() == .alertFirstButtonReturn {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        } else {
            UserDefaults.standard.set(true, forKey: Self.skippedKey)
        }
    }

    func refresh() { readDevices() }

    /// Seeds the fallback level for a device from an external source (e.g. BLE).
    /// Used so that charging state can be reported even before the first valid HID++ level read.
    func hintLevel(_ level: Int, forDevice name: String) {
        if lastKnownLevels[name] == nil, level >= 5 {
            lastKnownLevels[name] = level
        }
    }

    private func readDevices() {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
        HIDPPEngine.readAll(
            supported: Self.supportedPIDs,
            lastKnownLevels: lastKnownLevels,
            onDevicesFound: { [weak self] names in self?.onDevicesFound?(names) },
            completion: { [weak self] items in
                guard let self else { return }
                for item in items where item.level >= 5 {
                    self.lastKnownLevels[item.name] = item.level
                }
                self.onUpdate?(items)
            }
        )
    }
}

// MARK: - HID++ 2.0 engine

private final class ReportQueue {
    var reports: [Data] = []

    func dequeue(featIdx: UInt8, fnSW: UInt8) -> Data? {
        for (i, r) in reports.enumerated() {
            guard r.count >= 4 else { continue }
            if r[0] == 0x11 && r[1] == 0xFF && r[2] == 0xFF { reports.remove(at: i); return nil }
            if r[0] == 0x11 && r[1] == 0xFF && r[2] == featIdx && r[3] == fnSW {
                reports.remove(at: i)
                return r.count > 4 ? Data(r.dropFirst(4)) : Data()
            }
        }
        return nil
    }
}

private enum HIDPPEngine {
    private static let vendorID  = 0x046D
    private static let reportID: UInt8 = 0x11
    private static let devIdx:   UInt8 = 0xFF
    private static let swID:     UInt8 = 0x0A
    private static let frameLen  = 20
    private static let timeout:  TimeInterval = 1.5

    private static let features: [(code: UInt16, unified: Bool)] = [
        (0x1004, true),
        (0x1010, true),
        (0x1000, false),
    ]

    private static let chargingUnified: Set<Int> = [1, 2]
    private static let chargingLegacy:  Set<Int> = [1, 2, 3, 4]

    static func readAll(supported: [Int: String],
                        lastKnownLevels: [String: Int],
                        onDevicesFound: @escaping (Set<String>) -> Void,
                        completion: @escaping ([AccessoryBattery]) -> Void) {
        Thread.detachNewThread {
            let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
            IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: vendorID] as CFDictionary)
            IOHIDManagerOpen(mgr, 0)

            guard let devSet = IOHIDManagerCopyDevices(mgr) else {
                DispatchQueue.main.async { onDevicesFound([]); completion([]) }
                return
            }

            let count = CFSetGetCount(devSet)
            var ptrs = [UnsafeRawPointer?](repeating: nil, count: count)
            CFSetGetValues(devSet, &ptrs)

            var matched: [(dev: IOHIDDevice, name: String)] = []
            for ptr in ptrs {
                guard let ptr else { continue }
                let dev = unsafeBitCast(ptr, to: IOHIDDevice.self)
                let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0
                guard let name = supported[pid] else { continue }
                matched.append((dev, name))
            }

            let names = Set(matched.map { $0.name })
            DispatchQueue.main.async { onDevicesFound(names) }

            var results: [AccessoryBattery] = []
            for (dev, name) in matched {
                if let batt = queryDevice(dev: dev, name: name,
                                          lastKnownLevel: lastKnownLevels[name]) {
                    results.append(batt)
                }
            }

            DispatchQueue.main.async { completion(results) }
        }
    }

    private static func queryDevice(dev: IOHIDDevice, name: String,
                                    lastKnownLevel: Int?) -> AccessoryBattery? {
        guard IOHIDDeviceOpen(dev, 0) == kIOReturnSuccess else { return nil }
        defer { IOHIDDeviceClose(dev, 0) }

        let queue = ReportQueue()
        let qPtr  = Unmanaged.passRetained(queue).toOpaque()
        defer { Unmanaged<ReportQueue>.fromOpaque(qPtr).release() }

        var buf = [UInt8](repeating: 0, count: 64)
        IOHIDDeviceRegisterInputReportCallback(dev, &buf, CFIndex(buf.count), { ctx, result, _, _, _, report, len in
            guard result == kIOReturnSuccess, len > 0, let ctx else { return }
            let q = Unmanaged<ReportQueue>.fromOpaque(ctx).takeUnretainedValue()
            q.reports.append(Data(bytes: report, count: len))
        }, qPtr)

        let rl = RunLoop.current.getCFRunLoop()
        IOHIDDeviceScheduleWithRunLoop(dev, rl, CFRunLoopMode.defaultMode.rawValue)
        defer { IOHIDDeviceUnscheduleFromRunLoop(dev, rl, CFRunLoopMode.defaultMode.rawValue) }

        for feat in features {
            guard let featIdx = getFeatureIndex(dev: dev, queue: queue, code: feat.code) else { continue }

            let fn: UInt8 = feat.unified ? 1 : 0
            guard let resp = send(dev: dev, queue: queue, featIdx: featIdx, fn: fn) else { continue }

            guard resp.count >= 3 else { continue }
            let statusB  = Int(resp[2])
            let charging = feat.unified ? chargingUnified.contains(statusB)
                                        : chargingLegacy.contains(statusB)
            let pct: Int
            if !feat.unified && statusB == 3 {
                pct = 100
            } else if !feat.unified {
                let raw = Int(resp[0])
                if [5, 20, 50, 100].contains(raw) {
                    pct = raw
                } else if let knownLevel = lastKnownLevel {
                    // Level is a transient garbage value; use last known with current charging state.
                    return AccessoryBattery(name: name, level: knownLevel, charging: charging)
                } else {
                    continue
                }
            } else {
                pct = Int(resp[0])
            }
            guard pct >= 5 else { continue }
            return AccessoryBattery(name: name, level: min(100, pct), charging: charging)
        }
        return nil
    }

    private static func getFeatureIndex(dev: IOHIDDevice, queue: ReportQueue,
                                        code: UInt16) -> UInt8? {
        let params = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
        guard let resp = send(dev: dev, queue: queue, featIdx: 0x00, fn: 0, params: params),
              !resp.isEmpty else { return nil }
        let idx = resp[0]
        return idx > 0 ? idx : nil
    }

    private static func send(dev: IOHIDDevice, queue: ReportQueue,
                             featIdx: UInt8, fn: UInt8,
                             params: Data = Data()) -> Data? {
        let fnSW = ((fn & 0x0F) << 4) | swID
        var frame = Data([reportID, devIdx, featIdx, fnSW]) + params
        while frame.count < frameLen { frame.append(0) }

        queue.reports.removeAll()
        var bytes = [UInt8](frame)
        guard IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput,
                                   CFIndex(bytes[0]), &bytes, CFIndex(bytes.count)) == kIOReturnSuccess
        else { return nil }

        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            if let data = queue.dequeue(featIdx: featIdx, fnSW: fnSW) { return data }
        }
        return nil
    }
}
