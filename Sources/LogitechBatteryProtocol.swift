import Foundation

/// HID++ battery features have distinct functions and payloads. In particular,
/// 0x1010 is Charging Control, not Unified Battery (0x1004).
enum LogitechBatteryFeature: UInt16, CaseIterable {
    case unified = 0x1004
    case legacy = 0x1000

    var function: UInt8 { self == .unified ? 1 : 0 }

    func decode(_ payload: Data, lastKnownLevel: Int?) -> (level: Int, charging: Bool)? {
        let bytes = [UInt8](payload)
        guard bytes.count >= (self == .unified ? 4 : 3) else { return nil }
        let status = bytes[2]
        guard status <= 6 else { return nil }
        // Full (3) is not actively charging; slow recharge (4) is.
        let charging = [1, 2, 4].contains(status)
        let raw = Int(bytes[0])
        guard raw <= 100 else { return nil }
        let level: Int
        if status == 3 {
            level = 100
        } else if raw > 0 {
            level = raw
        } else if self == .unified, let approximate = [1: 5, 2: 20, 4: 50, 8: 100][Int(bytes[1])] {
            level = approximate
        } else if let known = lastKnownLevel, (0...100).contains(known) {
            // Some devices report an unavailable percentage while charging.
            level = known
        } else {
            return nil
        }
        return (level, charging)
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
        for item in items { readings[item.name] = (item, date) }
    }

    func current(at date: Date = Date()) -> [AccessoryBattery] {
        readings.values.filter { date.timeIntervalSince($0.date) < 120 }
            .map { $0.battery }.sorted { $0.name < $1.name }
    }
}

enum LogitechReply {
    static func match(_ report: Data, feature: UInt8, function: UInt8) -> Result<Data, LogitechReplyError>? {
        let bytes = [UInt8](report)
        guard bytes.count >= 4, [0x10, 0x11].contains(bytes[0]), bytes[1] == 0xFF else { return nil }
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
