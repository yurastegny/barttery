import XCTest
@testable import Barttery

final class WatchChargingTests: XCTestCase {
    private let now = Date()

    private func reading(at date: Date, level: Int = 80) -> WatchBattery {
        WatchBattery(name: "Apple Watch", level: level, isCharging: true, updatedAt: date)
    }

    func testLiveUnplugEventOverridesChargingImmediately() throws {
        var state = WatchChargingState()
        let plugged = try XCTUnwrap(state.receive(reading(at: now), powerEvent: true,
                                                 reportedCharging: true, at: now))
        XCTAssertTrue(plugged.isCharging)
        XCTAssertTrue(plugged.chargingKnown)
        let later = now.addingTimeInterval(15)
        let unplugged = try XCTUnwrap(state.receive(reading(at: later), powerEvent: true,
                                                   reportedCharging: false, at: later))
        XCTAssertFalse(unplugged.isCharging)
        XCTAssertTrue(unplugged.chargingKnown)
    }

    func testContinuousStreamPreservesChargingUntilUnplugEvent() throws {
        var state = WatchChargingState()
        state.streamHeartbeat(at: now)
        _ = state.receive(reading(at: now), powerEvent: true, reportedCharging: true, at: now)
        for seconds in stride(from: 15, through: 600, by: 15) {
            let date = now.addingTimeInterval(Double(seconds))
            state.streamHeartbeat(at: date)
            XCTAssertNil(state.expire(at: date))
        }
        let later = now.addingTimeInterval(600)
        let registry = try XCTUnwrap(state.receive(reading(at: later), powerEvent: false,
                                                  reportedCharging: false, at: later))
        XCTAssertTrue(registry.isCharging)
        let unplugged = try XCTUnwrap(state.receive(reading(at: later), powerEvent: true,
                                                   reportedCharging: false, at: later))
        XCTAssertFalse(unplugged.isCharging)
        XCTAssertTrue(unplugged.chargingKnown)
    }

    func testBrokenStreamCannotKeepOldChargingOrReviveItOnReconnect() throws {
        var state = WatchChargingState()
        state.streamHeartbeat(at: now)
        _ = state.receive(reading(at: now), powerEvent: true, reportedCharging: true, at: now)
        let later = now.addingTimeInterval(600)
        XCTAssertFalse(try XCTUnwrap(state.expire(at: later)).chargingKnown)
        state.streamHeartbeat(at: later)
        let result = try XCTUnwrap(state.receive(reading(at: later), powerEvent: false,
                                                reportedCharging: true, at: later))
        XCTAssertFalse(result.chargingKnown)
    }

    func testStaleRegistryTrueCannotOverwriteLiveUnpluggedState() throws {
        var state = WatchChargingState()
        _ = state.receive(reading(at: now), powerEvent: true, reportedCharging: false, at: now)
        let later = now.addingTimeInterval(30)
        let registry = try XCTUnwrap(state.receive(reading(at: later), powerEvent: false,
                                                  reportedCharging: true, at: later))
        XCTAssertFalse(registry.isCharging)
        XCTAssertTrue(registry.chargingKnown)
        XCTAssertEqual(state.observation?.observedAt, now)
    }

    func testRegistryReadCannotExtendOldChargingObservation() throws {
        var state = WatchChargingState()
        _ = state.receive(reading(at: now), powerEvent: true, reportedCharging: true, at: now)
        let later = now.addingTimeInterval(WatchChargingObservation.lifetime)
        let result = try XCTUnwrap(state.receive(reading(at: later), powerEvent: false,
                                                reportedCharging: true, at: later))
        XCTAssertFalse(result.chargingKnown)
        XCTAssertEqual(state.observation?.observedAt, now)
    }

    func testMissingChargingFieldDoesNotBecomeDischargingOrExtendObservation() throws {
        var state = WatchChargingState()
        _ = state.receive(reading(at: now), powerEvent: true, reportedCharging: true, at: now)
        let later = now.addingTimeInterval(30)
        let result = try XCTUnwrap(state.receive(reading(at: later), powerEvent: true,
                                                reportedCharging: nil, at: later))
        XCTAssertTrue(result.isCharging)
        XCTAssertEqual(state.observation?.observedAt, now)
        let expired = try XCTUnwrap(state.expire(at: now.addingTimeInterval(180)))
        XCTAssertFalse(expired.chargingKnown)
        XCTAssertEqual(expired.updatedAt, later) // Expiring status is not a new battery read.
    }

    func testUnknownRegistryStatusIsNotCalledNotCharging() throws {
        var state = WatchChargingState()
        let result = try XCTUnwrap(state.receive(reading(at: now), powerEvent: false,
                                                reportedCharging: true, at: now))
        XCTAssertFalse(result.chargingKnown)
    }

    func testInvalidLevelCannotChangeChargingObservation() {
        var state = WatchChargingState()
        XCTAssertNil(state.receive(reading(at: now, level: 255), powerEvent: true,
                                   reportedCharging: true, at: now))
        XCTAssertNil(state.observation)
    }

    func testLegacyAndExpiredCachedChargingFlagsAreNotRestored() throws {
        let suite = "Barttery.WatchChargingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "watch.lastPowerEventCharging")
        defaults.set(true, forKey: "watch.lastCharging")
        defaults.set(80, forKey: "watch.lastLevel")
        defaults.set(now, forKey: "watch.lastSyncTime")
        XCTAssertNil(WatchChargingObservation.cached(from: defaults, at: now))
        XCTAssertFalse(try XCTUnwrap(WatchBattery.cached(from: defaults, at: now)).chargingKnown)
        defaults.set(now.addingTimeInterval(-3600), forKey: "watch.lastPowerEventDate")
        XCTAssertNil(WatchChargingObservation.cached(from: defaults, at: now))
        defaults.set(now, forKey: "watch.lastPowerEventDate")
        XCTAssertTrue(try XCTUnwrap(WatchBattery.cached(from: defaults, at: now)).isCharging)
        defaults.set(false, forKey: "watch.lastPowerEventCharging")
        let unplugged = try XCTUnwrap(WatchBattery.cached(from: defaults, at: now))
        XCTAssertTrue(unplugged.chargingKnown)
        XCTAssertFalse(unplugged.isCharging)
    }

    func testUnknownStatusIsPreservedInWidgetSnapshots() throws {
        let item = WidgetBatteryDevice(id: "watch", name: "Watch", symbol: "applewatch",
                                       level: 80, isCharging: false, updatedAt: now, chargingKnown: false)
        XCTAssertNil(item.statusSymbol)
        XCTAssertEqual(item.statusDescription, "Battery 80%")
        XCTAssertEqual(try JSONDecoder().decode(WidgetBatteryDevice.self, from: JSONEncoder().encode(item)), item)
        let accessory = AccessoryBattery(name: "Mouse", level: 50, charging: true,
                                         updatedAt: now, chargingKnown: false)
        XCTAssertNil(WidgetBatteryDevice(accessory: accessory).statusSymbol)
        XCTAssertFalse(WidgetBatteryDevice(accessory: accessory).isCharging)
    }

    func testOldWidgetSnapshotsWithoutChargingKnownStillDecode() throws {
        let item = WidgetBatteryDevice(id: "watch", name: "Watch", symbol: "applewatch",
                                       level: 80, isCharging: true, updatedAt: now)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json.removeValue(forKey: "chargingKnown")
        let old = try JSONDecoder().decode(WidgetBatteryDevice.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.chargingKnown)
        XCTAssertTrue(old.isCharging)
    }

    func testTimedOutHelperIgnoringTerminateIsKilled() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; printf 'ready\\n'; exec /bin/sleep 30"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        XCTAssertFalse(output.fileHandleForReading.availableData.isEmpty)
        let start = Date()
        IDeviceReader.stopTimedOutHelper(process, grace: 0.05)
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
