import Combine
import Foundation
import OSLog
import WidgetKit

/// Only the host app talks to hardware. The extension consumes an atomic JSON snapshot.
final class WidgetSnapshotPublisher {
    private var changes: AnyCancellable?
    private var pendingReload: DispatchWorkItem?
    private var pendingReloadDelay: TimeInterval?
    private var lastReload = Date.distantPast
    private var hasPublishedSnapshot = false
    private var lastDeviceIDs: [String] = []
    private static let logger = Logger(subsystem: "me.yura.barttery", category: "Widget")

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
        let snapshot = monitor.widgetSnapshot()
        do {
            try WidgetSnapshotStore.write(snapshot)

            let ids = snapshot.devices.map(\.id)
            let listChanged = ids != lastDeviceIDs
            lastDeviceIDs = ids
            Self.logger.debug("Snapshot devices: \(ids.joined(separator: ", "), privacy: .public)")

            if !hasPublishedSnapshot {
                hasPublishedSnapshot = true
                lastReload = Date()
                Self.logger.notice("Initial device list: \(ids.joined(separator: ", "), privacy: .public)")
                Self.reloadAllWidgets()
            } else if listChanged {
                Self.logger.notice("Device list changed: \(ids.joined(separator: ", "), privacy: .public)")
                // The widget's device list must not wait for the value refresh: on
                // launch the first snapshot is Mac-only, and the other readers report
                // a second or two later. Reloading only on the value schedule left the
                // widget showing that Mac-only draft.
                requestReload(delay: 15, allKinds: true)
            } else {
                // Match the timeline cadence in BatteryTimelineProvider. Requesting a
                // reload every few minutes burns WidgetKit's daily refresh budget, so
                // later reloads get dropped and the widget looks frozen.
                requestReload(delay: 15 * 60, allKinds: false)
            }
        } catch {
            Self.logger.error("Cannot save widget snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func reloadAllWidgets() {
        guard Bundle.main.object(forInfoDictionaryKey: "BartteryWidgetsEnabled") as? Bool == true else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func requestReload(delay: TimeInterval, allKinds: Bool) {
        // Coalesce frequent BLE updates; WidgetKit also applies its own refresh budget.
        // A shorter pending reload wins, so a device-list change is not stuck behind
        // an already-scheduled five-minute value refresh.
        if let pendingDelay = pendingReloadDelay, pendingDelay <= delay {
            return
        }
        pendingReload?.cancel()
        pendingReload = nil
        pendingReloadDelay = nil

        let effective = max(0, delay - Date().timeIntervalSince(lastReload))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReload = nil
            self.pendingReloadDelay = nil
            self.lastReload = Date()
            if allKinds {
                WidgetCenter.shared.reloadAllTimelines()
            } else {
                for layout in WidgetBatteryLayout.allCases {
                    WidgetCenter.shared.reloadTimelines(ofKind: layout.widgetKind)
                }
            }
        }
        pendingReload = work
        pendingReloadDelay = effective
        DispatchQueue.main.asyncAfter(deadline: .now() + effective, execute: work)
    }
}

extension DeviceBatteryMonitor {
    func widgetSnapshot(at date: Date = Date()) -> WidgetBatterySnapshot {
        var devices: [WidgetBatteryDevice] = []
        func append(_ id: String, _ name: String, _ symbol: String, _ level: Int?, _ charging: Bool,
                    paused: Bool = false, updatedAt: Date, chargingKnown: Bool = true) {
            guard let level else { return }
            devices.append(WidgetBatteryDevice(id: id, name: name, symbol: symbol,
                                               level: min(100, max(0, level)),
                                                isCharging: charging, isPaused: paused, updatedAt: updatedAt,
                                                chargingKnown: chargingKnown))
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
                   updatedAt: watch.updatedAt, chargingKnown: watch.chargingKnown)
        }
        for accessory in accessories {
            devices.append(WidgetBatteryDevice(accessory: accessory))
        }
        return WidgetBatterySnapshot(devices: devices, writtenAt: date)
    }
}

extension WidgetBatteryDevice {
    init(accessory: AccessoryBattery) {
        self.init(id: "accessory.\(accessory.name)", name: accessory.name, symbol: accessory.icon,
                  level: min(100, max(0, accessory.level)), isCharging: accessory.charging,
                  updatedAt: accessory.updatedAt ?? .distantPast, chargingKnown: accessory.chargingKnown)
    }
}
