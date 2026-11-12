import Foundation

/// Shared by the menu bar app and the sandboxed WidgetKit extension.
struct WidgetBatteryDevice: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let symbol: String
    let level: Int
    let isCharging: Bool
    let isPaused: Bool
    let chargingKnown: Bool
    let updatedAt: Date

    init(id: String, name: String, symbol: String, level: Int, isCharging: Bool,
          isPaused: Bool = false, updatedAt: Date, chargingKnown: Bool = true) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.level = level
        self.isCharging = chargingKnown && isCharging
        self.isPaused = isPaused
        self.chargingKnown = chargingKnown
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, level, isCharging, isPaused, updatedAt, chargingKnown
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  name: try values.decode(String.self, forKey: .name),
                  symbol: try values.decode(String.self, forKey: .symbol),
                  level: try values.decode(Int.self, forKey: .level),
                  isCharging: try values.decode(Bool.self, forKey: .isCharging),
                  isPaused: try values.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false,
                  updatedAt: try values.decode(Date.self, forKey: .updatedAt),
                  chargingKnown: try values.decodeIfPresent(Bool.self, forKey: .chargingKnown) ?? true)
    }

    var statusSymbol: String? {
        if !chargingKnown { return nil }
        if isPaused { return "pause.fill" }
        return isCharging ? "bolt.fill" : nil
    }

    var statusDescription: String {
        if !chargingKnown { return "Battery \(level)%" }
        if isPaused { return "Charging paused" }
        return isCharging ? "Charging" : "On battery"
    }

    func isStale(at date: Date) -> Bool {
        let age = date.timeIntervalSince(updatedAt)
        return !age.isFinite || age < -60 || age >= WidgetBatterySnapshot.staleInterval
    }
}

struct WidgetBatterySnapshot: Codable, Equatable {
    static let staleInterval: TimeInterval = 30 * 60
    let devices: [WidgetBatteryDevice]
    let writtenAt: Date

    static let empty = WidgetBatterySnapshot(devices: [], writtenAt: .distantPast)

    var displayedDevices: [WidgetBatteryDevice] { Array(devices.prefix(4)) }

    func displayedDevices(for layout: WidgetBatteryLayout) -> [WidgetBatteryDevice] {
        Array(devices.prefix(layout.capacity))
    }

    static func placeholder(at date: Date = Date(), layout: WidgetBatteryLayout = .fourWide) -> WidgetBatterySnapshot {
        let examples = [
            WidgetBatteryDevice(id: "mac", name: "MacBook", symbol: "macbook", level: 82, isCharging: true, updatedAt: date),
            WidgetBatteryDevice(id: "phone", name: "iPhone", symbol: "iphone", level: 64, isCharging: false, updatedAt: date),
            WidgetBatteryDevice(id: "airpods", name: "AirPods", symbol: "airpods", level: 47, isCharging: false, updatedAt: date),
            WidgetBatteryDevice(id: "watch", name: "Apple Watch", symbol: "applewatch", level: 91, isCharging: false, updatedAt: date),
            WidgetBatteryDevice(id: "pad", name: "iPad", symbol: "ipad", level: 20, isCharging: false, updatedAt: date),
            WidgetBatteryDevice(id: "keyboard", name: "Keyboard", symbol: "keyboard", level: 76, isCharging: false, updatedAt: date),
            WidgetBatteryDevice(id: "mouse", name: "Mouse", symbol: "computermouse", level: 15, isCharging: true, updatedAt: date),
            WidgetBatteryDevice(id: "case", name: "AirPods Case", symbol: "airpods.chargingcase", level: 92, isCharging: false, updatedAt: date)
        ]
        return WidgetBatterySnapshot(devices: Array(examples.prefix(layout.capacity)), writtenAt: date)
    }
}

enum WidgetBatteryLayout: String, CaseIterable {
    case single, fourSquare, fourWide, table

    var capacity: Int {
        switch self {
        case .single: return 1
        case .fourSquare, .fourWide: return 4
        case .table: return 8
        }
    }

    var columns: Int {
        switch self {
        case .single, .table: return 1
        case .fourSquare: return 2
        case .fourWide: return 4
        }
    }

    var isCompact: Bool { self == .fourSquare }

    var widgetKind: String {
        self == .fourWide ? "BartteryBatteries" : "BartteryBatteries.\(rawValue)"
    }
}

enum WidgetSnapshotStore {
    static let appGroup = "group.me.yura.barttery"
    static let widgetKind = "BartteryBatteries"

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("battery-snapshot.json")
    }

    static func read(from url: URL? = fileURL) -> WidgetBatterySnapshot {
        guard let url,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetBatterySnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    static func write(_ snapshot: WidgetBatterySnapshot, to url: URL? = fileURL) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }
}
