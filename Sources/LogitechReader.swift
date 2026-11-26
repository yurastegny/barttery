import AppKit
import Foundation
import IOKit
import IOKit.hid
import os

// Reads battery level and charging state from supported Logitech devices via HID++ 2.0.
// Uses IOKit in shared (non-exclusive) mode with Input Monitoring permission.
// If permission is not granted the reader returns no results and BLEDeviceReader
// serves as a fallback (discrete levels, trend-based charging).
// Protocol modeled on https://github.com/pcolman/mx-battery (MIT).
class LogitechReader {
    private static let logger = Logger(subsystem: "me.yura.barttery", category: "LogitechBattery")
    private var lastAccessGranted: Bool?
    var onUpdate: (([AccessoryBattery]) -> Void)?
    var onChargingUpdate: (([LogitechChargingReading]) -> Void)?
    /// Called immediately after IOKit enumeration, before battery queries complete.
    /// Provides visible device names so callers can remove disconnected devices.
    /// Visibility alone must not suppress battery readings from fallback readers.
    var onDevicesFound: ((Set<String>) -> Void)?
    private var timer: Timer?
    private var lastKnownLevels: [String: Int] = [:]
    private var isReading = false

    static let supportedPIDs: [Int: String] = [
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
        0xB020: "MX Vertical",
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

    static func canonicalName(for name: String) -> String? {
        func normalized(_ value: String) -> String {
            String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        let key = normalized(name)
        return supportedPIDs.values.first { normalized($0) == key }
    }

    private static let skippedKey = "logitech.inputMonitoring.skipped"

    func startMonitoring() {
        timer?.invalidate()
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if access == kIOHIDAccessTypeUnknown,
           !UserDefaults.standard.bool(forKey: Self.skippedKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.requestPermissionWithExplanation()
            }
        }
        readDevices()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.readDevices()
        }
    }

    private func requestPermissionWithExplanation() {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted else {
            readDevices()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Logitech Device Battery"
        alert.informativeText = "To monitor the battery level and charging status of Logitech devices, Input Monitoring permission is required. Skip this if you don't have any Logitech devices."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Skip")
        alert.alertStyle = .informational
        if alert.runModal() == .alertFirstButtonReturn {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            readDevices()
        } else {
            UserDefaults.standard.set(true, forKey: Self.skippedKey)
        }
    }

    func refresh() { readDevices() }

    /// Seeds the fallback level for a device from an external source (e.g. BLE).
    /// Used so that charging state can be reported even before the first valid HID++ level read.
    func hintLevel(_ level: Int, forDevice name: String) {
        if lastKnownLevels[name] == nil, (0...100).contains(level) {
            lastKnownLevels[name] = level
        }
    }

    private func readDevices() {
        guard !isReading else { return }
        let accessGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if lastAccessGranted != accessGranted {
            Self.logger.notice("HID battery access granted: \(accessGranted, privacy: .public)")
            lastAccessGranted = accessGranted
        }
        guard accessGranted else {
            onDevicesFound?([])
            onChargingUpdate?([])
            onUpdate?([])
            return
        }
        isReading = true
        HIDPPEngine.readAll(
            supported: Self.supportedPIDs,
            lastKnownLevels: lastKnownLevels,
            onDevicesFound: { [weak self] names in self?.onDevicesFound?(names) },
            onChargingUpdate: { [weak self] readings in self?.onChargingUpdate?(readings) },
            completion: { [weak self] items in
                guard let self else { return }
                self.isReading = false
                for item in items {
                    self.lastKnownLevels[item.name] = item.level
                }
                self.onUpdate?(items)
            }
        )
    }

    deinit { timer?.invalidate() }
}

// MARK: - HID++ 2.0 engine

private final class ReportQueue {
    var reports: [Data] = []

    func dequeue(featIdx: UInt8, fnSW: UInt8) -> Result<Data, LogitechReplyError>? {
        for (i, r) in reports.enumerated() {
            if let reply = LogitechReply.match(r, feature: featIdx, function: fnSW) {
                reports.remove(at: i)
                return reply
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
    private static let logger = Logger(subsystem: "me.yura.barttery", category: "LogitechBattery")

    static func readAll(supported: [Int: String],
                        lastKnownLevels: [String: Int],
                        onDevicesFound: @escaping (Set<String>) -> Void,
                        onChargingUpdate: @escaping ([LogitechChargingReading]) -> Void,
                        completion: @escaping ([AccessoryBattery]) -> Void) {
        Thread.detachNewThread {
            let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
            IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: vendorID] as CFDictionary)
            guard IOHIDManagerOpen(mgr, 0) == kIOReturnSuccess else {
                logger.notice("Cannot open Logitech IOHIDManager")
                DispatchQueue.main.async { onDevicesFound([]); completion([]) }
                return
            }
            defer { IOHIDManagerClose(mgr, 0) }

            guard let devSet = IOHIDManagerCopyDevices(mgr) else {
                logger.notice("Logitech IOHIDManager returned no devices")
                DispatchQueue.main.async { onDevicesFound([]); completion([]) }
                return
            }

            let count = CFSetGetCount(devSet)
            var ptrs = [UnsafeRawPointer?](repeating: nil, count: count)
            CFSetGetValues(devSet, &ptrs)

            var matched: [(dev: IOHIDDevice, name: String)] = []
            var fallback: [(dev: IOHIDDevice, name: String)] = []
            for ptr in ptrs {
                guard let ptr else { continue }
                let dev = unsafeBitCast(ptr, to: IOHIDDevice.self)
                let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0
                let product = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? "?"
                let transport = (IOHIDDeviceGetProperty(dev, kIOHIDTransportKey as CFString) as? String) ?? "?"
                let page = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? -1
                let usage = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? -1
                let hasVendor = hasHIDPPCollection(dev)
                logger.notice("HID node \(product, privacy: .public) pid=0x\(String(format: "%04X", pid), privacy: .public) transport=\(transport, privacy: .public) usagePage=0x\(String(format: "%04X", page), privacy: .public) usage=0x\(String(format: "%04X", usage), privacy: .public) hidpp=\(hasVendor, privacy: .public)")

                guard let name = supported[pid] else { continue }
                if hasVendor {
                    matched.append((dev, name))
                } else {
                    fallback.append((dev, name))
                }
            }
            // BLE-direct devices expose the mouse and HID++ collections as separate
            // HID nodes. Prefer the node that actually carries the vendor collection;
            // opening the mouse node can block or time out.
            if matched.isEmpty { matched = fallback }
            logger.notice("Logitech HID++ candidates: \(matched.map { $0.name }.joined(separator: ", "), privacy: .public)")

            let names = Set(matched.map { $0.name })
            DispatchQueue.main.async { onDevicesFound(names) }

            var results: [AccessoryBattery] = []
            var chargingResults: [LogitechChargingReading] = []
            for (dev, name) in matched {
                if let status = queryDevice(dev: dev, lastKnownLevel: lastKnownLevels[name]) {
                    let date = Date()
                    if status.chargingKnown {
                        chargingResults.append(LogitechChargingReading(name: name, charging: status.charging, updatedAt: date))
                    }
                    if let level = status.level, status.reportsLevel {
                        results.append(AccessoryBattery(name: name, level: level, charging: status.charging,
                                                        updatedAt: date, chargingKnown: status.chargingKnown))
                    }
                }
            }

            DispatchQueue.main.async {
                onChargingUpdate(chargingResults)
                completion(results)
            }
        }
    }

    /// USB/HID++ exposes usage page 0xFF00; Bluetooth LE uses 0xFF43.
    /// Receiver-backed devices may not publish the pair on this node, so callers
    /// fall back to matching by product ID when nothing advertises the vendor page.
    private static func hasHIDPPCollection(_ dev: IOHIDDevice) -> Bool {
        if let pairs = IOHIDDeviceGetProperty(dev, "DeviceUsagePairs" as CFString) as? [[String: Any]] {
            for pair in pairs {
                let page = (pair["DeviceUsagePage"] as? NSNumber)?.intValue
                    ?? (pair["DeviceUsagePage"] as? Int) ?? -1
                if page == 0xFF43 || page == 0xFF00 { return true }
            }
        }
        let page = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? -1
        return page == 0xFF43 || page == 0xFF00
    }

    private static func queryDevice(dev: IOHIDDevice,
                                    lastKnownLevel: Int?) -> LogitechBatteryStatus? {
        let openResult = IOHIDDeviceOpen(dev, 0)
        guard openResult == kIOReturnSuccess else {
            logger.notice("Cannot open Logitech HID device: 0x\(String(format: "%08X", UInt32(bitPattern: openResult)), privacy: .public). Another app may hold it exclusively (Logi Options+, Karabiner).")
            return nil
        }
        defer { IOHIDDeviceClose(dev, 0) }

        let queue = ReportQueue()
        let qPtr  = Unmanaged.passRetained(queue).toOpaque()
        defer { Unmanaged<ReportQueue>.fromOpaque(qPtr).release() }

        // IOKit keeps this pointer until the callback is unregistered.
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        defer { buf.deallocate() }
        IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, { ctx, result, _, _, reportID, report, len in
            guard result == kIOReturnSuccess, len > 0, let ctx else { return }
            let q = Unmanaged<ReportQueue>.fromOpaque(ctx).takeUnretainedValue()
            var data = Data(bytes: report, count: len)
            // IOKit passes the report ID separately and the buffer may or may not
            // already contain it (this differs between USB and BLE nodes). Normalise
            // to the HID++ report format used by LogitechReply.match.
            if reportID != 0, data.first != UInt8(truncatingIfNeeded: reportID) {
                data.insert(UInt8(truncatingIfNeeded: reportID), at: 0)
            }
            q.reports.append(data)
        }, qPtr)

        let rl = RunLoop.current.getCFRunLoop()
        IOHIDDeviceScheduleWithRunLoop(dev, rl, CFRunLoopMode.defaultMode.rawValue)
        defer {
            IOHIDDeviceUnscheduleFromRunLoop(dev, rl, CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, nil, nil)
        }

        for feat in LogitechBatteryFeature.allCases {
            guard let featIdx = getFeatureIndex(dev: dev, queue: queue, code: feat.rawValue) else {
                logger.notice("Feature 0x\(String(format: "%04X", feat.rawValue), privacy: .public) not found")
                continue
            }
            guard let resp = send(dev: dev, queue: queue, featIdx: featIdx, fn: feat.function) else {
                logger.notice("Feature 0x\(String(format: "%04X", feat.rawValue), privacy: .public) did not reply")
                continue
            }
            guard let battery = feat.decodeStatus(resp, lastKnownLevel: lastKnownLevel) else {
                logger.notice("Feature 0x\(String(format: "%04X", feat.rawValue), privacy: .public) response undecodable: \(resp.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "), privacy: .public)")
                continue
            }
            logger.notice("Battery 0x\(String(format: "%04X", feat.rawValue), privacy: .public) level=\(String(describing: battery.level), privacy: .public) charging=\(battery.charging, privacy: .public)")
            return battery
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
        let sendResult = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput,
                                              CFIndex(bytes[0]), &bytes, CFIndex(bytes.count))
        guard sendResult == kIOReturnSuccess else {
            logger.notice("HID++ SetReport failed: 0x\(String(format: "%08X", UInt32(bitPattern: sendResult)), privacy: .public)")
            return nil
        }

        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            if let reply = queue.dequeue(featIdx: featIdx, fnSW: fnSW) {
                if case .success(let data) = reply {
                    logger.notice("HID++ reply: \(data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "), privacy: .public)")
                } else {
                    logger.notice("HID++ error reply for feature 0x\(String(format: "%02X", featIdx), privacy: .public)")
                }
                return try? reply.get()
            }
        }
        return nil
    }
}
