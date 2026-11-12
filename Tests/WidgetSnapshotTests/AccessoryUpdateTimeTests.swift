import XCTest
@testable import Barttery

final class AccessoryUpdateTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRenamingLogitechPreservesItsOwnMeasurementDate() {
        let original = AccessoryBattery(name: "MX Keys", level: 80, charging: false, updatedAt: now)
        // A user-assigned name can stop matching the keyboard name heuristic.
        let renamed = original.renamed("Yura's desk")
        XCTAssertEqual(original.batteryDevice, .keyboard)
        XCTAssertEqual(renamed.batteryDevice, .mouse)
        XCTAssertEqual(renamed.updatedAt, now)
        XCTAssertEqual(BatteryUpdateAge.text(since: renamed.updatedAt, at: now), "Just now")
        XCTAssertEqual(renamed.level, original.level)
    }

    func testUnknownMeasurementDateStaysUnknownAfterRenaming() {
        let cached = AccessoryBattery(name: "MX Master", level: 50, charging: false)
        XCTAssertNil(cached.renamed("Mouse").updatedAt)
        XCTAssertEqual(BatteryUpdateAge.text(since: cached.updatedAt, at: now), "Not updated yet")
    }

    func testWidgetUsesEachAccessoryDateInsteadOfItsSharedCategory() {
        let old = AccessoryBattery(name: "Mouse A", level: 50, charging: false,
                                   updatedAt: now.addingTimeInterval(-3600))
        let fresh = AccessoryBattery(name: "Mouse B", level: 80, charging: false, updatedAt: now)
        XCTAssertEqual(old.batteryDevice, fresh.batteryDevice)
        XCTAssertTrue(WidgetBatteryDevice(accessory: old).isStale(at: now))
        XCTAssertFalse(WidgetBatteryDevice(accessory: fresh).isStale(at: now))
        let unknown = AccessoryBattery(name: "Mouse C", level: 30, charging: false)
        XCTAssertTrue(WidgetBatteryDevice(accessory: unknown).isStale(at: now))
        let future = AccessoryBattery(name: "Mouse D", level: 30, charging: false,
                                      updatedAt: now.addingTimeInterval(3600))
        XCTAssertTrue(WidgetBatteryDevice(accessory: future).isStale(at: now))
    }

    func testPartialHIDUpdatesAndCacheReadsDoNotRefreshOtherDevices() throws {
        var cache = LogitechBatteryCache()
        let mouse = AccessoryBattery(name: "Mouse", level: 50, charging: false, updatedAt: now)
        cache.record([mouse, AccessoryBattery(name: "Keyboard", level: 80, charging: false)], at: now)
        cache.record([AccessoryBattery(name: "Keyboard", level: 79, charging: false)], at: now.addingTimeInterval(90))
        let items = cache.current(at: now.addingTimeInterval(100))
        XCTAssertEqual(try XCTUnwrap(items.first { $0.name == "Mouse" }).updatedAt, now)
        XCTAssertEqual(try XCTUnwrap(items.first { $0.name == "Keyboard" }).updatedAt, now.addingTimeInterval(90))
        cache.record([mouse], at: now.addingTimeInterval(110))
        XCTAssertEqual(cache.current(at: now.addingTimeInterval(120)).map(\.name), ["Keyboard"])
    }

    func testBLEPublishingAnotherDeviceDoesNotRefreshExistingReading() throws {
        let reader = BLEDeviceReader()
        let mouse = UUID(), keyboard = UUID()
        XCTAssertTrue(reader.recordBatteryLevel(50, for: mouse, at: now))
        XCTAssertTrue(reader.recordBatteryLevel(80, for: keyboard, at: now.addingTimeInterval(90)))
        XCTAssertEqual(try XCTUnwrap(reader.batteryReading(for: mouse, name: "Mouse")).updatedAt, now)
        XCTAssertEqual(try XCTUnwrap(reader.batteryReading(for: keyboard, name: "Keyboard")).updatedAt,
                       now.addingTimeInterval(90))
        // Reading the cache or renaming it never advances the measurement clock.
        XCTAssertEqual(try XCTUnwrap(reader.batteryReading(for: mouse, name: "New name")).updatedAt, now)
    }

    func testSuccessfulUnchangedBLEReadIsFreshButRejectedReadIsNot() throws {
        let reader = BLEDeviceReader()
        let id = UUID()
        reader.recordBatteryLevel(80, for: id, at: now)
        let later = now.addingTimeInterval(60)
        XCTAssertTrue(reader.recordBatteryLevel(80, for: id, at: later))
        XCTAssertEqual(reader.batteryReading(for: id, name: "Mouse")?.updatedAt, later)
        for invalid in [0, 4, 101, 255, 20] {
            XCTAssertFalse(reader.recordBatteryLevel(invalid, for: id, at: later.addingTimeInterval(60)))
            XCTAssertEqual(reader.batteryReading(for: id, name: "Mouse")?.updatedAt, later)
        }
    }

    func testElapsedFormattingUsesReadableUnitsWithoutEnormousCounters() {
        for (age, expected): (TimeInterval, String) in [
            (0, "Just now"), (59, "Just now"), (60, "1 min ago"),
            (3599, "59 min ago"), (3600, "1 h ago"), (86400, "1 d ago"),
            (1000 * 3600, "Over 30 days ago")
        ] {
            XCTAssertEqual(BatteryUpdateAge.text(since: now.addingTimeInterval(-age), at: now), expected)
        }
    }

    func testSentinelDatesClockChangesAndNonFiniteDatesDoNotOverflow() {
        XCTAssertEqual(BatteryUpdateAge.text(since: .distantPast, at: now), "Unknown")
        XCTAssertEqual(BatteryUpdateAge.text(since: .distantFuture, at: now), "Unknown")
        XCTAssertEqual(BatteryUpdateAge.text(since: Date(timeIntervalSinceReferenceDate: -.infinity), at: now), "Unknown")
        XCTAssertEqual(BatteryUpdateAge.text(since: now.addingTimeInterval(3600), at: now), "Unknown")
        XCTAssertEqual(BatteryUpdateAge.text(since: now.addingTimeInterval(30), at: now), "Just now")
    }
}
