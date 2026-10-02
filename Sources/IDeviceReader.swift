import Foundation
import AppKit

struct WatchBattery {
    let name: String
    let level: Int
    let isCharging: Bool
}

// Reads iPhone/iPad battery via bartbeat (persistent libimobiledevice daemon with heartbeat)
// and Apple Watch battery via comptest.
class IDeviceReader: NSObject {
    var onPhoneUpdate: ((Int?, Bool?, String?) -> Void)?
    var onPadUpdate:   ((Int?, Bool?, String?) -> Void)?
    var onWatchUpdate: ((WatchBattery?) -> Void)?

    private var binDir = ""
    private var libDir = ""
    private var bartbeat: Process?
    private var staleTimer: Timer?
    private var lastPhoneSuccess: Date?
    private var lastPadSuccess:   Date?
    private var lastWatchSuccess: Date?
    private var phoneUDID: String?
    private var lastBartbeatOutput: Date?
    private var lastBartbeatRestart: Date?

    func start() {
        guard let resURL = Bundle.main.resourceURL else { return }
        binDir = resURL.path
        libDir = resURL.path
        prepareBinaries()
        launchBartbeat()
        // Seed success timestamps from UserDefaults so the stale check works for
        // values restored from cache before any live bartbeat update arrives.
        let ud = UserDefaults.standard
        if let t = ud.object(forKey: "phone.lastSyncTime") as? Date { lastPhoneSuccess = t }
        if let t = ud.object(forKey: "pad.lastSyncTime") as? Date   { lastPadSuccess = t }
        if let t = ud.object(forKey: "watch.lastSyncTime") as? Date { lastWatchSuccess = t }
        phoneUDID = ud.string(forKey: "phone.lastUDID")
        staleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkStale()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func onWake() {
        lastBartbeatRestart = nil  // bypass cooldown on wake
        restartBartbeat()
    }

    /// Re-query Watch via comptest. Phone/pad come from bartbeat's own poll loop.
    func scanNow() {
        let udid = phoneUDID ?? UserDefaults.standard.string(forKey: "phone.lastUDID")
        guard let udid else { return }
        phoneUDID = udid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.queryWatch(udid: udid)
        }
    }

    /// Kill and relaunch bartbeat, then re-query Watch. Used on popup open / wake.
    func forceReconnect() {
        lastBartbeatRestart = nil
        restartBartbeat()
        scanNow()
    }

    // MARK: - bartbeat process

    private func launchBartbeat() {
        if let proc = bartbeat, proc.isRunning { return }
        let path = (binDir as NSString).appendingPathComponent("bartbeat")
        guard FileManager.default.fileExists(atPath: path) else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.environment = ProcessInfo.processInfo.environment.merging(
            ["DYLD_LIBRARY_PATH": libDir]
        ) { _, new in new }

        let outPipe = Pipe()
        let inPipe  = Pipe()   // kept open so bartbeat's stdin doesn't get EOF
        proc.standardOutput = outPipe
        proc.standardInput  = inPipe
        proc.standardError  = Pipe()

        var lineBuf = ""
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let chunk = String(data: h.availableData, encoding: .utf8) else { return }
            lineBuf += chunk
            while let nl = lineBuf.firstIndex(of: "\n") {
                let line = String(lineBuf[lineBuf.startIndex..<nl])
                lineBuf.removeSubrange(lineBuf.startIndex...nl)
                if !line.isEmpty { self?.handle(line: line) }
            }
        }

        proc.terminationHandler = { [weak self] _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self?.launchBartbeat()
            }
        }

        try? proc.run()
        bartbeat = proc
    }

    private func handle(line: String) {
        lastBartbeatOutput = Date()
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {

        case "phone":
            let level    = json["level"] as? Int
            let charging = json["charging"] as? Bool ?? false
            let name     = json["name"] as? String
            let udid     = json["udid"] as? String
            lastPhoneSuccess = Date()
            if let udid { phoneUDID = udid; UserDefaults.standard.set(udid, forKey: "phone.lastUDID") }
            if let level {
                UserDefaults.standard.set(level, forKey: "phone.lastBattery")
                UserDefaults.standard.set(Date(), forKey: "phone.lastSyncTime")
                if let name, !name.isEmpty { UserDefaults.standard.set(name, forKey: "phone.lastName") }
            }
            DispatchQueue.main.async { [weak self] in self?.onPhoneUpdate?(level, charging, name) }

        case "pad":
            let level    = json["level"] as? Int
            let charging = json["charging"] as? Bool ?? false
            let name     = json["name"] as? String
            lastPadSuccess = Date()
            if let level {
                UserDefaults.standard.set(level, forKey: "pad.lastBattery")
                UserDefaults.standard.set(Date(), forKey: "pad.lastSyncTime")
                if let name, !name.isEmpty { UserDefaults.standard.set(name, forKey: "pad.lastName") }
            }
            DispatchQueue.main.async { [weak self] in self?.onPadUpdate?(level, charging, name) }

        case "connected":
            if json["device_type"] as? String == "phone", let udid = json["udid"] as? String {
                phoneUDID = udid
                UserDefaults.standard.set(udid, forKey: "phone.lastUDID")
            }

        case "watch":
            let level    = json["level"] as? Int
            let charging = json["charging"] as? Bool ?? false
            let name     = json["name"] as? String
            lastWatchSuccess = Date()
            if let level {
                UserDefaults.standard.set(level,      forKey: "watch.lastLevel")
                UserDefaults.standard.set(charging,   forKey: "watch.lastCharging")
                UserDefaults.standard.set(Date(),     forKey: "watch.lastSyncTime")
                if let name, !name.isEmpty { UserDefaults.standard.set(name, forKey: "watch.lastName") }
                let watch = WatchBattery(
                    name:       name ?? UserDefaults.standard.string(forKey: "watch.lastName") ?? "Apple Watch",
                    level:      level,
                    isCharging: charging
                )
                DispatchQueue.main.async { [weak self] in self?.onWatchUpdate?(watch) }
            }

        case "disconnected":
            break   // keep showing last known values

        default: break
        }
    }

    // MARK: - Apple Watch (via comptest)

    private func queryWatch(udid: String) {
        let out = run("comptest", [udid])
        guard let watch = parseWatch(out) else { return }
        lastWatchSuccess = Date()
        UserDefaults.standard.set(watch.level,      forKey: "watch.lastLevel")
        UserDefaults.standard.set(watch.isCharging, forKey: "watch.lastCharging")
        UserDefaults.standard.set(watch.name,       forKey: "watch.lastName")
        UserDefaults.standard.set(Date(),           forKey: "watch.lastSyncTime")
        DispatchQueue.main.async { [weak self] in self?.onWatchUpdate?(watch) }
    }

    private func parseWatch(_ output: String) -> WatchBattery? {
        var name     = ""
        var level    = -1
        var charging = false
        var inWatch  = false
        for line in output.components(separatedBy: "\n") {
            if line.contains("Checking watch") { inWatch = true }
            guard inWatch else { continue }
            if line.contains("DeviceName")             { name     = line.value(for: "DeviceName") }
            if line.contains("BatteryCurrentCapacity") { level    = Int(line.value(for: "BatteryCurrentCapacity")) ?? -1 }
            if line.contains("BatteryIsCharging")      { charging = line.value(for: "BatteryIsCharging").lowercased() == "true" }
        }
        guard level >= 0 else { return nil }
        return WatchBattery(name: name.isEmpty ? "Apple Watch" : name, level: level, isCharging: charging)
    }

    // MARK: - Stale timeouts

    private func restartBartbeat() {
        let cooldown: TimeInterval = 180
        if let last = lastBartbeatRestart, Date().timeIntervalSince(last) < cooldown { return }
        lastBartbeatRestart = Date()
        lastBartbeatOutput  = Date()  // reset so we don't loop immediately
        // Prefer SIGKILL: a wedged bartbeat can ignore SIGTERM and stay alive for hours.
        if let proc = bartbeat, proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        bartbeat = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.launchBartbeat()
        }
    }

    private func checkStale() {
        let now = Date()
        let deviceTimeout: TimeInterval = 1800

        // Restart bartbeat if stdout has been silent for 3 min — even when success
        // timestamps were already cleared. Otherwise a wedged daemon is never replaced.
        let silent = lastBartbeatOutput.map { now.timeIntervalSince($0) > 180 }
            ?? (bartbeat?.isRunning == true && now.timeIntervalSince(lastBartbeatRestart ?? .distantPast) > 180)
        if silent {
            restartBartbeat()
        }

        // Keep trying to recover when a known phone/pad hasn't synced recently,
        // even if bartbeat is still emitting non-battery noise (connected/etc).
        let ud = UserDefaults.standard
        let phoneSyncAge = (ud.object(forKey: "phone.lastSyncTime") as? Date)
            .map { now.timeIntervalSince($0) }
        let padSyncAge = (ud.object(forKey: "pad.lastSyncTime") as? Date)
            .map { now.timeIntervalSince($0) }
        if !silent, (phoneSyncAge ?? 0) > deviceTimeout || (padSyncAge ?? 0) > deviceTimeout {
            restartBartbeat()
        }

        let phoneStale = lastPhoneSuccess.map { now.timeIntervalSince($0) > deviceTimeout } ?? false
        let padStale   = lastPadSuccess.map   { now.timeIntervalSince($0) > deviceTimeout } ?? false

        // Watch: hide after 30 minutes without a successful query
        if let t = lastWatchSuccess, now.timeIntervalSince(t) > deviceTimeout {
            lastWatchSuccess = nil
            DispatchQueue.main.async { [weak self] in self?.onWatchUpdate?(nil) }
        }

        // iPhone / iPad: hide after 30 minutes
        if phoneStale {
            lastPhoneSuccess = nil
            lastWatchSuccess = nil
            DispatchQueue.main.async { [weak self] in
                self?.onPhoneUpdate?(nil, nil, nil)
                self?.onWatchUpdate?(nil)
            }
        }
        if padStale {
            lastPadSuccess = nil
            DispatchQueue.main.async { [weak self] in self?.onPadUpdate?(nil, nil, nil) }
        }
    }

    // MARK: - Process helpers

    private func prepareBinaries() {
        let fm = FileManager.default
        for name in ["bartbeat", "comptest"] {
            let path = (binDir as NSString).appendingPathComponent(name)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
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
            while proc.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if proc.isRunning { proc.terminate() }
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

// MARK: - String helpers

private extension String {
    func value(for key: String) -> String {
        for line in components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(key + ":") {
                return t.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
}
