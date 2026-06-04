import Foundation
import ServiceManagement
import Combine

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var launchAtLogin: Bool
    @Published var notificationThresholds: [String: Set<Int>] = [:]

    private var bag = Set<AnyCancellable>()
    private var isRevertingLaunchAtLogin = false

    private init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled

        if let data = UserDefaults.standard.data(forKey: "notificationThresholds"),
           let decoded = try? JSONDecoder().decode([String: [Int]].self, from: data) {
            notificationThresholds = decoded.mapValues { Set($0) }
        }

        $launchAtLogin.dropFirst().sink { [weak self] enabled in
            guard let self, !isRevertingLaunchAtLogin else { return }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else       { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Failed to update Launch at Login: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isRevertingLaunchAtLogin = true
                    self.launchAtLogin = SMAppService.mainApp.status == .enabled
                    self.isRevertingLaunchAtLogin = false
                }
            }
        }.store(in: &bag)

        $notificationThresholds.dropFirst().sink { thresholds in
            let encodable = thresholds.mapValues { Array($0) }
            if let data = try? JSONEncoder().encode(encodable) {
                UserDefaults.standard.set(data, forKey: "notificationThresholds")
            }
        }.store(in: &bag)
    }

    func isThresholdEnabled(device: BatteryDevice, threshold: Int) -> Bool {
        notificationThresholds[device.rawValue]?.contains(threshold) ?? false
    }

    func toggleThreshold(device: BatteryDevice, threshold: Int) {
        var set = notificationThresholds[device.rawValue] ?? []
        if set.contains(threshold) {
            set.remove(threshold)
        } else {
            set.insert(threshold)
            NotificationManager.shared.requestPermission()
        }
        notificationThresholds[device.rawValue] = set
    }
}
