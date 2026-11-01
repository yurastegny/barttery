import Combine
import Foundation
import OSLog
import WidgetKit

/// Only the host app talks to hardware. The extension consumes an atomic JSON snapshot.
final class WidgetSnapshotPublisher {
    private var changes: AnyCancellable?
    private var pendingReload: DispatchWorkItem?
    private var lastReload = Date.distantPast
    private var hasPublishedSnapshot = false
    private static let logger = Logger(subsystem: "com.yura.barttery", category: "Widget")

    init(monitor: DeviceBatteryMonitor) {
        changes = monitor.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self, weak monitor] _ in
                guard let self, let monitor else { return }
                self.publish(monitor)
            }
        publish(monitor)
    }

    deinit { pendingReload?.cancel() }

    private func publish(_ monitor: DeviceBatteryMonitor) {
        // The plain SwiftPM/DMG build deliberately has no App Group entitlement.
        guard Bundle.main.object(forInfoDictionaryKey: "BartteryWidgetsEnabled") as? Bool == true else { return }
        do {
            try WidgetSnapshotStore.write(monitor.widgetSnapshot())
            if !hasPublishedSnapshot {
                hasPublishedSnapshot = true
                lastReload = Date()
                Self.reloadAllWidgets()
            } else {
                requestReload()
            }
        } catch {
            Self.logger.error("Cannot save widget snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func reloadAllWidgets() {
        guard Bundle.main.object(forInfoDictionaryKey: "BartteryWidgetsEnabled") as? Bool == true else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func requestReload() {
        guard pendingReload == nil else { return }
        // Coalesce frequent BLE updates; WidgetKit also applies its own refresh budget.
        let delay = max(0, 5 * 60 - Date().timeIntervalSince(lastReload))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReload = nil
            self.lastReload = Date()
            for layout in WidgetBatteryLayout.allCases {
                WidgetCenter.shared.reloadTimelines(ofKind: layout.widgetKind)
            }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

extension DeviceBatteryMonitor {
    func widgetSnapshot(at date: Date = Date()) -> WidgetBatterySnapshot {
        var devices: [WidgetBatteryDevice] = []
        func append(_ id: String, _ name: String, _ symbol: String, _ level: Int?, _ charging: Bool,
                    paused: Bool = false, updatedAt: Date) {
            guard let level else { return }
            devices.append(WidgetBatteryDevice(id: id, name: name, symbol: symbol,
                                               level: min(100, max(0, level)),
                                               isCharging: charging, isPaused: paused, updatedAt: updatedAt))
        }

        if let mac = macBattery {
            append("mac", macName, "macbook", mac.level, mac.state == .charging,
                   paused: mac.state == .paused,
                   updatedAt: macBatteryUpdatedAt ?? .distantPast)
        }
        append("phone", phoneName, "iphone", phoneBattery, phoneCharging,
               updatedAt: syncTimes[BatteryDevice.phone.rawValue] ?? .distantPast)
        append("pad", padName, "ipad", padBattery, padCharging,
               updatedAt: syncTimes[BatteryDevice.pad.rawValue] ?? .distantPast)
        if let pods = airPodsBattery {
            // One ring for the earbuds, using the lower available level.
            let level = [pods.left, pods.right].compactMap { $0 }.min()
            let updatedAt = syncTimes[BatteryDevice.airPods.rawValue] ?? .distantPast
            append("airpods", airPodsName, "airpods", level,
                   pods.leftCharging || pods.rightCharging, updatedAt: updatedAt)
            append("airpods.case", "\(airPodsName) Case", "airpods.chargingcase", pods.case,
                   pods.caseCharging, updatedAt: updatedAt)
        }
        if let watch = watchBattery {
            append("watch", watch.name, "applewatch", watch.level, watch.isCharging,
                   updatedAt: syncTimes[BatteryDevice.watch.rawValue] ?? .distantPast)
        }
        for accessory in accessories {
            append("accessory.\(accessory.name)", accessory.name, accessory.icon, accessory.level,
                   accessory.charging, updatedAt: syncTimes[accessory.batteryDevice.rawValue] ?? .distantPast)
        }
        return WidgetBatterySnapshot(devices: devices, writtenAt: date)
    }
}
