import Foundation

/// A live Watch power observation has a different lifetime from a cached
/// companion-registry battery percentage. Never refresh it with registry reads.
struct WatchChargingObservation: Equatable {
    static let lifetime: TimeInterval = 180
    let charging: Bool
    let observedAt: Date

    func value(at date: Date) -> Bool? {
        let age = date.timeIntervalSince(observedAt)
        guard age.isFinite, age >= -60, age < Self.lifetime else { return nil }
        return charging
    }

    static func cached(from defaults: UserDefaults = .standard, at date: Date = Date()) -> Self? {
        guard let value = defaults.object(forKey: "watch.lastPowerEventCharging") as? Bool,
              let observedAt = defaults.object(forKey: "watch.lastPowerEventDate") as? Date else { return nil }
        let observation = Self(charging: value, observedAt: observedAt)
        return observation.value(at: date) == nil ? nil : observation
    }
}

struct WatchChargingState {
    private(set) var observation: WatchChargingObservation?
    private(set) var lastReading: WatchBattery?
    private var streamStartedAt: Date?
    private var streamHeartbeatAt: Date?

    mutating func streamHeartbeat(at date: Date) {
        if let previous = streamHeartbeatAt, (0..<45).contains(date.timeIntervalSince(previous)) {
            streamHeartbeatAt = date
        } else {
            streamStartedAt = date
            streamHeartbeatAt = date
        }
    }

    private func charging(at date: Date) -> Bool? {
        if let observation, let started = streamStartedAt, let heartbeat = streamHeartbeatAt,
           observation.observedAt >= started,
           (0..<45).contains(date.timeIntervalSince(heartbeat)) {
            // An uninterrupted live subscription preserves a transition state;
            // silence is not a charger-disconnect event.
            return observation.charging
        }
        return observation?.value(at: date)
    }

    init(observation: WatchChargingObservation? = nil, lastReading: WatchBattery? = nil) {
        self.observation = observation
        self.lastReading = lastReading
    }

    mutating func receive(_ reading: WatchBattery, powerEvent: Bool,
                          reportedCharging: Bool?, at date: Date) -> WatchBattery? {
        guard (0...100).contains(reading.level) else { return nil }
        if powerEvent, let reportedCharging {
            observation = WatchChargingObservation(charging: reportedCharging, observedAt: date)
        }
        let result = reading.withChargingStatus(charging(at: date))
        lastReading = result
        return result
    }

    mutating func expire(at date: Date) -> WatchBattery? {
        guard let lastReading, lastReading.chargingKnown,
              charging(at: date) == nil else { return nil }
        let result = lastReading.withChargingStatus(nil)
        self.lastReading = result
        return result
    }
}

extension WatchBattery {
    func withChargingStatus(_ charging: Bool?) -> WatchBattery {
        WatchBattery(name: name, level: level, isCharging: charging ?? false,
                     chargingKnown: charging != nil, updatedAt: updatedAt)
    }

    static func cached(from defaults: UserDefaults = .standard, at date: Date = Date()) -> WatchBattery? {
        guard let updatedAt = defaults.object(forKey: "watch.lastSyncTime") as? Date,
              (-60..<1800).contains(date.timeIntervalSince(updatedAt)),
              let level = defaults.object(forKey: "watch.lastLevel") as? Int,
              (0...100).contains(level) else { return nil }
        let status = WatchChargingObservation.cached(from: defaults, at: date)?.value(at: date)
        return WatchBattery(name: defaults.string(forKey: "watch.lastName") ?? "Apple Watch",
                            level: level, isCharging: status ?? false,
                            chargingKnown: status != nil, updatedAt: updatedAt)
    }
}
