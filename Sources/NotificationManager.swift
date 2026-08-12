import UserNotifications
import AppKit

enum BatteryDevice: String {
    case mac, phone, pad, watch, airPods, keyboard, mouse, trackpad

    var label: String {
        switch self {
        case .mac:      return "MacBook"
        case .phone:    return "iPhone"
        case .pad:      return "iPad"
        case .watch:    return "Apple Watch"
        case .airPods:  return "AirPods"
        case .keyboard: return "Keyboard"
        case .mouse:    return "Mouse"
        case .trackpad: return "Trackpad"
        }
    }
}

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private struct DeviceState {
        var lastLevel: Int?
        var notifiedThresholds: Set<Int> = []
        var wasCharging = false
    }

    private var states: [BatteryDevice: DeviceState] = [:]

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func check(device: BatteryDevice, level: Int, isCharging: Bool) {
        let settings = AppSettings.shared
        var state = states[device] ?? DeviceState()
        defer { states[device] = state }

        // Charging started or level rose → reset discharge notifications
        if isCharging && !state.wasCharging {
            state.notifiedThresholds = state.notifiedThresholds.filter { $0 >= 80 }
        }
        if let prev = state.lastLevel, level > prev {
            state.notifiedThresholds = state.notifiedThresholds.filter { $0 >= 80 }
        }
        state.wasCharging = isCharging

        let prev = state.lastLevel
        state.lastLevel = level

        // Charging thresholds: 80% and 100%
        for threshold in [80, 100] {
            if isCharging,
               let prev, prev < threshold, level >= threshold,
               !state.notifiedThresholds.contains(threshold),
               settings.isThresholdEnabled(device: device, threshold: threshold) {
                send(device: device, level: threshold, isCharging: true)
                state.notifiedThresholds.insert(threshold)
            }
            if level < threshold { state.notifiedThresholds.remove(threshold) }
        }

        // Discharge threshold: 20%
        guard !isCharging, let prev, level < prev else { return }
        if !state.notifiedThresholds.contains(20),
           prev > 20, level <= 20,
           settings.isThresholdEnabled(device: device, threshold: 20) {
            send(device: device, level: 20, isCharging: false)
            state.notifiedThresholds.insert(20)
        }
    }

    private func send(device: BatteryDevice, level: Int, isCharging: Bool) {
        let content = UNMutableNotificationContent()
        content.title = device.label
        content.body  = isCharging
            ? (level == 100 ? "Fully charged" : "Charged to \(level)%")
            : "Time to charge — \(level)% remaining"
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "battery-\(device.rawValue)-\(level)",
            content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }
}
