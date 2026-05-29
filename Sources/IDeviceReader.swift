import Foundation
import IOKit

struct WatchBattery {
    let name: String
    let level: Int
    let isCharging: Bool
}

class IDeviceReader: NSObject {
    var onPhoneUpdate: ((Int?, Bool?, String?) -> Void)?
    var onPadUpdate:   ((Int?, Bool?, String?) -> Void)?
    var onWatchUpdate: ((WatchBattery?) -> Void)?

    private var timer: Timer?
    private var binDir: String = ""
    private var libDir: String = ""
    private var foundPhone  = false
    private var foundPad    = false
    private var lastPhoneSuccess: Date?
    private var lastPadSuccess:   Date?
    private var lastWatchSuccess: Date?
    private var isScanning   = false
    private var pendingScan  = false
    private let foundLock    = NSLock()
    private var serviceBrowser: NetServiceBrowser?
    private var usbNotifyPort: IONotificationPortRef?
    private var usbIterator: io_iterator_t = 0

    func start() {
        guard let resURL = Bundle.module.resourceURL else { return }
        binDir = resURL.path
        libDir = resURL.path  // dylibs are at bundle root (SPM flattens subdirs)
        prepareBinaries()
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            self?.scan()
        }
        startBonjourWatch()
        startUSBWatch()
    }

    func scanNow() { scan(immediate: true) }

    // MARK: - Bonjour (WiFi)

    private func startBonjourWatch() {
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: "_apple-mobdev2._tcp.", inDomain: "local.")
        serviceBrowser = browser
    }

    // MARK: - IOKit (USB)

    private func startUSBWatch() {
        usbNotifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = usbNotifyPort else { return }

        let src = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)

        var matchDict = IOServiceMatching("IOUSBHostDevice") as! [String: Any]
        matchDict["idVendor"] = 0x05AC  // Apple

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(
            port, kIOMatchedNotification, matchDict as CFDictionary,
            { refCon, it in
                guard let refCon else { return }
                let reader = Unmanaged<IDeviceReader>.fromOpaque(refCon).takeUnretainedValue()
                var svc = IOIteratorNext(it)
                while svc != 0 { IOObjectRelease(svc); svc = IOIteratorNext(it) }
                reader.scan(immediate: true)
            },
            selfPtr, &usbIterator
        )

        // Drain the seeding iteration so future callbacks fire only for new devices
        var svc = IOIteratorNext(usbIterator)
        while svc != 0 { IOObjectRelease(svc); svc = IOIteratorNext(usbIterator) }
    }

    // MARK: - Private

    private func prepareBinaries() {
        let fm = FileManager.default
        for name in ["idevice_id", "ideviceinfo", "comptest"] {
            let path = (binDir as NSString).appendingPathComponent(name)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    private func scan(immediate: Bool = false) {
        if isScanning {
            if immediate { pendingScan = true }
            return
        }
        isScanning = true
        pendingScan = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.scanDevices()
            self?.isScanning = false
            if self?.pendingScan == true {
                self?.scan(immediate: true)
            }
        }
    }

    private func scanDevices() {
        let usbUDIDs  = run("idevice_id", ["-n"]).lines.filter { !$0.isEmpty }
        let allUDIDs  = run("idevice_id", ["-l"]).lines.filter { !$0.isEmpty }
        let wifiUDIDs = allUDIDs.filter { !usbUDIDs.contains($0) }

        foundPhone = false
        foundPad   = false

        let group = DispatchGroup()
        let allPairs = usbUDIDs.map { ($0, true) } + wifiUDIDs.map { ($0, false) }
        for (udid, usb) in allPairs {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                self.readDevice(udid: udid, usb: usb)
                group.leave()
            }
        }
        group.wait()

        let now = Date()
        if !foundPhone, let t = lastPhoneSuccess, now.timeIntervalSince(t) > 900 {
            lastPhoneSuccess = nil
            DispatchQueue.main.async { [weak self] in self?.onPhoneUpdate?(nil, nil, nil) }
        }
        if !foundPhone, let t = lastWatchSuccess, now.timeIntervalSince(t) > 900 {
            lastWatchSuccess = nil
            DispatchQueue.main.async { [weak self] in self?.onWatchUpdate?(nil) }
        }
        if !foundPad, let t = lastPadSuccess, now.timeIntervalSince(t) > 900 {
            lastPadSuccess = nil
            DispatchQueue.main.async { [weak self] in self?.onPadUpdate?(nil, nil, nil) }
        }
    }

    private func readDevice(udid: String, usb: Bool) {
        let flag = usb ? ["-n"] : [String]()

        let info = run("ideviceinfo", flag + ["-u", udid])
        guard !info.isEmpty else { return }

        let deviceClass = info.value(for: "DeviceClass").lowercased()
        guard deviceClass == "iphone" || deviceClass == "ipad" else { return }

        let battInfo = run("ideviceinfo", flag + ["-q", "com.apple.mobile.battery", "-u", udid])
        guard let level = Int(battInfo.value(for: "BatteryCurrentCapacity")), level >= 0 else { return }

        let charging = battInfo.value(for: "BatteryIsCharging").lowercased() == "true"
        let name     = info.value(for: "DeviceName")

        if deviceClass == "iphone" {
            foundLock.lock()
            foundPhone = true
            lastPhoneSuccess = Date()
            foundLock.unlock()
            UserDefaults.standard.set(level,   forKey: "phone.lastBattery")
            UserDefaults.standard.set(Date(),  forKey: "phone.lastSyncTime")
            if !name.isEmpty { UserDefaults.standard.set(name, forKey: "phone.lastName") }
            DispatchQueue.main.async { [weak self] in
                self?.onPhoneUpdate?(level, charging, name.isEmpty ? nil : name)
            }
            syncWatch(udid: udid, flag: flag)
        } else {
            foundLock.lock()
            foundPad = true
            lastPadSuccess = Date()
            foundLock.unlock()
            UserDefaults.standard.set(level,   forKey: "pad.lastBattery")
            UserDefaults.standard.set(Date(),  forKey: "pad.lastSyncTime")
            if !name.isEmpty { UserDefaults.standard.set(name, forKey: "pad.lastName") }
            DispatchQueue.main.async { [weak self] in
                self?.onPadUpdate?(level, charging, name.isEmpty ? nil : name)
            }
        }
    }

    private func syncWatch(udid: String, flag: [String]) {
        let watchOut = run("comptest", [udid])
        guard let watch = parseWatch(watchOut) else { return }
        lastWatchSuccess = Date()
        UserDefaults.standard.set(watch.level,      forKey: "watch.lastLevel")
        UserDefaults.standard.set(watch.isCharging, forKey: "watch.lastCharging")
        UserDefaults.standard.set(watch.name,       forKey: "watch.lastName")
        UserDefaults.standard.set(Date(),           forKey: "watch.lastSyncTime")
        DispatchQueue.main.async { [weak self] in
            self?.onWatchUpdate?(watch)
        }
    }

    private func parseWatch(_ output: String) -> WatchBattery? {
        var name      = ""
        var level     = -1
        var charging  = false
        var inWatch   = false

        for line in output.lines {
            if line.contains("Checking watch") { inWatch = true }
            guard inWatch else { continue }
            if line.contains("DeviceName")              { name     = line.value(for: "DeviceName") }
            if line.contains("BatteryCurrentCapacity")  { level    = Int(line.value(for: "BatteryCurrentCapacity")) ?? -1 }
            if line.contains("BatteryIsCharging")       { charging = line.value(for: "BatteryIsCharging").lowercased() == "true" }
        }

        guard level >= 0 else { return nil }
        return WatchBattery(name: name.isEmpty ? "Apple Watch" : name, level: level, isCharging: charging)
    }

    @discardableResult
    private func run(_ binary: String, _ args: [String], timeout: TimeInterval = 10) -> String {
        let path = (binDir as NSString).appendingPathComponent(binary)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.environment = ProcessInfo.processInfo.environment.merging(
            ["DYLD_LIBRARY_PATH": libDir]
        ) { _, new in new }
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError  = err
        do {
            try proc.run()
            let deadline = Date().addingTimeInterval(timeout)
            while proc.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning { proc.terminate() }
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

// MARK: - NetServiceBrowserDelegate

extension IDeviceReader: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        scan(immediate: true)
    }
}

// MARK: - String helpers

private extension String {
    var lines: [String] { components(separatedBy: "\n") }

    func value(for key: String) -> String {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(key + ":") {
                return trimmed.dropFirst(key.count + 1)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
}
