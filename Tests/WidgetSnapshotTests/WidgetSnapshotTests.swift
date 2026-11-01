import XCTest
@testable import Barttery

final class WidgetSnapshotTests: XCTestCase {
    func testEachLayoutLimitsDevicesAndHasUniqueKind() {
        let now = Date()
        let devices = (0..<10).map {
            WidgetBatteryDevice(id: "device.\($0)", name: "Device \($0)", symbol: "iphone",
                                level: 50, isCharging: false, updatedAt: now)
        }
        let snapshot = WidgetBatterySnapshot(devices: devices, writtenAt: now)
        for layout in WidgetBatteryLayout.allCases {
            XCTAssertEqual(WidgetBatterySnapshot.placeholder(layout: layout).devices.count, layout.capacity)
            XCTAssertEqual(snapshot.displayedDevices(for: layout).count, layout.capacity)
            XCTAssertEqual(snapshot.displayedDevices(for: layout).map(\.id), Array(devices.prefix(layout.capacity)).map(\.id))
            XCTAssertTrue(WidgetBatterySnapshot.empty.displayedDevices(for: layout).isEmpty)
        }
        XCTAssertEqual(snapshot.displayedDevices(for: .single).count, 1)
        XCTAssertEqual(snapshot.displayedDevices(for: .fourSquare).count, 4)
        XCTAssertEqual(snapshot.displayedDevices(for: .table).count, 8)
        XCTAssertFalse(WidgetBatteryLayout.allCases.map(\.widgetKind).contains("BartteryBatteries.eightWide"))
        XCTAssertEqual(WidgetBatteryLayout.fourWide.widgetKind, WidgetSnapshotStore.widgetKind)
        XCTAssertEqual(Set(WidgetBatteryLayout.allCases.map(\.widgetKind)).count, 4)
    }

    func testChargingAndPausedIndicators() throws {
        let now = Date()
        let charging = WidgetBatteryDevice(id: "mac", name: "MacBook", symbol: "macbook", level: 80,
                                           isCharging: true, updatedAt: now)
        let paused = WidgetBatteryDevice(id: "mac", name: "MacBook", symbol: "macbook", level: 80,
                                         isCharging: false, isPaused: true, updatedAt: now)
        let discharging = WidgetBatteryDevice(id: "mac", name: "MacBook", symbol: "macbook", level: 80,
                                              isCharging: false, updatedAt: now)
        XCTAssertEqual(charging.statusSymbol, "bolt.fill")
        XCTAssertEqual(paused.statusSymbol, "pause.fill")
        XCTAssertEqual(paused.statusDescription, "Charging paused")
        XCTAssertNil(discharging.statusSymbol)
        let data = try JSONEncoder().encode(paused)
        XCTAssertEqual(try JSONDecoder().decode(WidgetBatteryDevice.self, from: data), paused)
    }

    func testOldSnapshotsWithoutPauseStillDecode() throws {
        let device = WidgetBatterySnapshot.placeholder().devices[0]
        let data = try JSONEncoder().encode(device)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "isPaused")
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(WidgetBatteryDevice.self, from: legacyData)
        XCTAssertFalse(decoded.isPaused)
        XCTAssertEqual(decoded.statusSymbol, "bolt.fill")
    }

    func testSnapshotRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = WidgetBatterySnapshot.placeholder(at: Date(timeIntervalSince1970: 1234))
        try WidgetSnapshotStore.write(snapshot, to: url)
        XCTAssertEqual(WidgetSnapshotStore.read(from: url), snapshot)
        // Replacing an existing snapshot must also be atomic and decodable.
        try WidgetSnapshotStore.write(.empty, to: url)
        XCTAssertEqual(WidgetSnapshotStore.read(from: url), .empty)
    }

    func testMissingAndCorruptSnapshotsAreEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(WidgetSnapshotStore.read(from: nil), .empty)
        XCTAssertEqual(WidgetSnapshotStore.read(from: url), .empty)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(WidgetSnapshotStore.read(from: url), .empty)
        XCTAssertThrowsError(try WidgetSnapshotStore.write(.empty, to: nil))
    }

    func testStalenessUsesMeasurementTimeNotSnapshotWriteTime() {
        let now = Date()
        let device = WidgetBatteryDevice(id: "phone", name: "iPhone", symbol: "iphone", level: 50,
                                         isCharging: false, updatedAt: now)
        XCTAssertFalse(device.isStale(at: now.addingTimeInterval(1799)))
        XCTAssertTrue(device.isStale(at: now.addingTimeInterval(1800)))
        let rewritten = WidgetBatterySnapshot(devices: [device], writtenAt: now.addingTimeInterval(3600))
        XCTAssertTrue(rewritten.displayedDevices[0].isStale(at: rewritten.writtenAt))
    }

    func testOnlyFirstFourDevicesAreDisplayed() {
        let sample = WidgetBatterySnapshot.placeholder()
        let extra = WidgetBatteryDevice(id: "mouse", name: "Mouse", symbol: "computermouse",
                                        level: 10, isCharging: false, updatedAt: Date())
        let snapshot = WidgetBatterySnapshot(devices: sample.devices + [extra], writtenAt: Date())
        XCTAssertEqual(snapshot.displayedDevices.count, 4)
        XCTAssertEqual(snapshot.displayedDevices.map(\.id), sample.devices.map(\.id))
        XCTAssertTrue(WidgetBatterySnapshot.empty.displayedDevices.isEmpty)
    }
}
