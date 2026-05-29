import Foundation
import AppKit

class DeviceBatteryMonitor: ObservableObject {
    @Published var macBattery:    MacBattery?  = nil
    @Published var macName:       String       = Host.current().localizedName ?? "Mac"
    @Published var phoneBattery:  Int?         = cachedBattery("phone")
    @Published var phoneCharging: Bool         = false
    @Published var phoneName:     String       = UserDefaults.standard.string(forKey: "phone.lastName") ?? "iPhone"
    @Published var padBattery:    Int?         = cachedBattery("pad")
    @Published var padCharging:   Bool         = false
    @Published var padName:       String       = UserDefaults.standard.string(forKey: "pad.lastName") ?? "iPad"
    @Published var watchBattery:  WatchBattery? = {
        let ud = UserDefaults.standard
        guard let t = ud.object(forKey: "watch.lastSyncTime") as? Date,
              Date().timeIntervalSince(t) < 1800 else { return nil }
        guard let level = ud.object(forKey: "watch.lastLevel") as? Int, level >= 0 else { return nil }
        return WatchBattery(
            name:        ud.string(forKey: "watch.lastName") ?? "Apple Watch",
            level:       level,
            isCharging:  ud.bool(forKey: "watch.lastCharging")
        )
    }()
    @Published var menuBarIcon:   NSImage      = renderPlugIcon()
    @Published var syncTimes:     [String: Date] = {
        let ud = UserDefaults.standard
        var times: [String: Date] = [:]
        for key in ["phone", "pad", "watch"] {
            if let t = ud.object(forKey: "\(key).lastSyncTime") as? Date,
               Date().timeIntervalSince(t) < 1800 {
                times[key] = t
            }
        }
        return times
    }()

    @Published var airPodsBattery:   AirPodsBattery? = nil
    @Published var airPodsConnected: Bool = false
    @Published var airPodsName:      String = "AirPods"
    @Published var accessories:      [AccessoryBattery] = []

    private var macReader:       MacBatteryReader?
    private var ideviceReader:   IDeviceReader?
    private var airPodsReader:   AirPodsReader?
    private var accessoryReader: AccessoryReader?
    private var refreshTimer:    Timer?
    private var retryTimer:      Timer?

    init() {
        setupMac()
        setupIDevice()
        setupAirPods()
        setupAccessories()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        macReader?.readNow()
        accessoryReader?.readOnce()
        ideviceReader?.scanNow()
    }

    func onPopupOpen() {
        let openTime = Date()
        refresh()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if syncTimes.values.contains(where: { $0 > openTime }) {
                retryTimer?.invalidate()
                retryTimer = nil
            } else {
                refresh()
            }
        }
    }

    func onPopupClose() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    // MARK: - Setup

    private func setupMac() {
        let reader = MacBatteryReader()
        reader.onUpdate = { [weak self] battery in
            self?.macBattery = battery
            self?.rebuildIcon()
            if let battery = battery {
                NotificationManager.shared.check(
                    device: .mac,
                    level: battery.level,
                    isCharging: battery.state == .charging
                )
            }
        }
        reader.start()
        macReader = reader
    }

    private func setupIDevice() {

        let reader = IDeviceReader()

        reader.onPhoneUpdate = { [weak self] level, charging, name in
            DispatchQueue.main.async {
                self?.phoneBattery  = level
                self?.phoneCharging = charging ?? false
                if let name { self?.phoneName = name }
                if let level {
                    self?.syncTimes[BatteryDevice.phone.rawValue] = Date()
                    NotificationManager.shared.check(
                        device: .phone,
                        level: level,
                        isCharging: charging ?? false
                    )
                }
            }
        }

        reader.onPadUpdate = { [weak self] level, charging, name in
            DispatchQueue.main.async {
                self?.padBattery  = level
                self?.padCharging = charging ?? false
                if let name { self?.padName = name }
                if let level {
                    self?.syncTimes[BatteryDevice.pad.rawValue] = Date()
                    NotificationManager.shared.check(
                        device: .pad,
                        level: level,
                        isCharging: charging ?? false
                    )
                }
            }
        }

        reader.onWatchUpdate = { [weak self] watch in
            DispatchQueue.main.async {
                self?.watchBattery = watch
                if let watch {
                    self?.syncTimes[BatteryDevice.watch.rawValue] = Date()
                    NotificationManager.shared.check(
                        device: .watch,
                        level: watch.level,
                        isCharging: watch.isCharging
                    )
                }
            }
        }

        reader.start()
        ideviceReader = reader
    }

    private func setupAirPods() {
        let reader = AirPodsReader()
        reader.onConnect = { [weak self] name in
            self?.airPodsName = name
        }
        reader.onUpdate = { [weak self] battery in
            self?.airPodsBattery = battery
            self?.airPodsConnected = reader.isConnected
            if let name = reader.deviceName { self?.airPodsName = name }
            if let battery,
               let minLevel = [battery.left, battery.right].compactMap({ $0 }).min() {
                self?.syncTimes[BatteryDevice.airPods.rawValue] = Date()
                NotificationManager.shared.check(
                    device: .airPods,
                    level: minLevel,
                    isCharging: battery.leftCharging || battery.rightCharging
                )
            }
        }
        reader.startMonitoring()
        airPodsReader = reader
    }

    private func setupAccessories() {
        if let cached = UserDefaults.standard.array(forKey: "accessories.last") as? [[String: Any]] {
            accessories = cached.compactMap {
                guard let name = $0["name"] as? String, let level = $0["level"] as? Int else { return nil }
                return AccessoryBattery(name: name, level: level, charging: false)
            }
        }

        let reader = AccessoryReader()
        reader.onUpdate = { [weak self] items in
            self?.accessories = items
            let cache = items.map { ["name": $0.name, "level": $0.level] as [String: Any] }
            UserDefaults.standard.set(cache, forKey: "accessories.last")
            for item in items {
                self?.syncTimes[item.batteryDevice.rawValue] = Date()
                NotificationManager.shared.check(device: item.batteryDevice, level: item.level, isCharging: item.charging)
            }
        }
        reader.startMonitoring()
        accessoryReader = reader
    }

    // MARK: - Icon

    private func rebuildIcon() {
        guard let mac = macBattery else {
            menuBarIcon = renderPlugIcon()
            return
        }
        menuBarIcon = renderBatteryIcon(level: mac.level, state: mac.state)
    }
}

private func cachedBattery(_ device: String) -> Int? {
    let ud = UserDefaults.standard
    guard let t = ud.object(forKey: "\(device).lastSyncTime") as? Date,
          Date().timeIntervalSince(t) < 1800 else { return nil }
    return ud.object(forKey: "\(device).lastBattery") as? Int
}
