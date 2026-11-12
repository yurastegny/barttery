import Foundation

struct LogitechBatteryStatus {
    let level: Int?
    let charging: Bool
    let chargingKnown: Bool
    let reportsLevel: Bool
}

/// HID++ battery features have distinct functions and payloads. In particular,
/// 0x1010 is Charging Control, not Unified Battery (0x1004).
enum LogitechBatteryFeature: UInt16, CaseIterable {
    case unified = 0x1004
    case legacy = 0x1000

    var function: UInt8 { self == .unified ? 1 : 0 }

    func decode(_ payload: Data, lastKnownLevel: Int?) -> (level: Int, charging: Bool)? {
        guard let status = decodeStatus(payload, lastKnownLevel: lastKnownLevel),
              let level = status.level else { return nil }
        return (level, status.charging)
    }

    /// Some devices (notably MX Master 2S on its charger) report a valid
    /// charging state with an unavailable percentage. Do not discard that state.
    func decodeStatus(_ payload: Data, lastKnownLevel: Int?) -> LogitechBatteryStatus? {
        let bytes = [UInt8](payload)
        guard bytes.count >= (self == .unified ? 4 : 3) else { return nil }
        let status = bytes[2]
        guard status <= 6 else { return nil }
        // 1 = charging, 2 = slow charging, 3 = full. Unified Battery uses
        // 4 for a charging error, while legacy Battery Status uses it for a
        // slow recharge. "Full" still represents external charging power and
        // keeps the lightning indicator visible; charging errors do not.
        let charging = status == 1 || status == 2 || status == 3 || (self == .legacy && status == 4)
        let raw = Int(bytes[0])
        guard raw <= 100 else { return nil }
        let level: Int?
        var reportsLevel = true
        if status == 3 {
            level = 100
        } else if raw > 0 {
            level = raw
        } else if self == .unified, let approximate = [1: 5, 2: 20, 4: 50, 8: 100][Int(bytes[1])] {
            level = approximate
        } else if let known = lastKnownLevel, (0...100).contains(known) {
            // Some devices report an unavailable percentage while charging.
            level = known
            reportsLevel = false
        } else {
            level = nil
            reportsLevel = false
        }
        let chargingKnown = self == .unified ? status <= 3 : status <= 4
        return LogitechBatteryStatus(level: level, charging: charging,
                                      chargingKnown: chargingKnown, reportsLevel: reportsLevel)
    }
}

struct LogitechChargingReading {
    let name: String
    let charging: Bool
    let updatedAt: Date
}

struct LogitechChargingCache {
    private var readings: [String: LogitechChargingReading] = [:]

    mutating func retainVisible(_ names: Set<String>) {
        readings = readings.filter { names.contains($0.key) }
    }

    mutating func record(_ items: [LogitechChargingReading]) {
        for item in items { readings[item.name] = item }
    }

    func applying(to item: AccessoryBattery, canonicalName: String, at date: Date = Date()) -> AccessoryBattery {
        guard let reading = readings[canonicalName],
              (0..<120).contains(date.timeIntervalSince(reading.updatedAt)) else { return item }
        var result = item
        result.charging = reading.charging
        result.chargingKnown = true
        return result
    }
}

enum LogitechReplyError: Error { case deviceError }

/// Keep brief HID++ timeouts from erasing other devices, but do not present a
/// cached charging flag indefinitely when a device stops answering.
struct LogitechBatteryCache {
    private var readings: [String: (battery: AccessoryBattery, date: Date)] = [:]

    mutating func retainVisible(_ names: Set<String>) {
        readings = readings.filter { names.contains($0.key) }
    }

    mutating func record(_ items: [AccessoryBattery], at date: Date = Date()) {
        for var item in items {
            // Preserve an existing measurement date when retaining/merging a
            // reading. A cache lookup must never make old data look fresh.
            let measuredAt = item.updatedAt ?? date
            item.updatedAt = measuredAt
            readings[item.name] = (item, measuredAt)
        }
    }

    func current(at date: Date = Date()) -> [AccessoryBattery] {
        readings.values.filter { date.timeIntervalSince($0.date) < 120 }
            .map { $0.battery }.sorted { $0.name < $1.name }
    }
}

enum LogitechReply {
    static func match(_ report: Data, feature: UInt8, function: UInt8) -> Result<Data, LogitechReplyError>? {
        let bytes = [UInt8](report)
        // Direct Bluetooth HID++ devices may answer with device index 0x00;
        // receiver-backed devices echo the request's 0xFF index.
        guard bytes.count >= 4, [0x10, 0x11].contains(bytes[0]),
              bytes[1] == 0xFF || bytes[1] == 0x00 else { return nil }
        if bytes[2] == feature, bytes[3] == function {
            return .success(Data(bytes.dropFirst(4)))
        }
        // HID++ 2.0 errors echo the feature and function of the failed request.
        if bytes.count >= 6, bytes[2] == 0xFF, bytes[3] == feature, bytes[4] == function {
            return .failure(.deviceError)
        }
        return nil
    }
}
