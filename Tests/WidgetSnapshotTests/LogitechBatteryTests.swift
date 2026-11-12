import XCTest
@testable import Barttery

final class LogitechBatteryTests: XCTestCase {
    func testLegacyAcceptsContinuousAndCriticalPercentages() throws {
        for level in [1, 4, 5, 37, 99, 100] {
            let result = try XCTUnwrap(LogitechBatteryFeature.legacy.decode(Data([UInt8(level), 0, 0]), lastKnownLevel: 80))
            XCTAssertEqual(result.level, level)
            XCTAssertFalse(result.charging)
        }
    }

    func testChargingStatusesForBothFeatures() throws {
        for feature in LogitechBatteryFeature.allCases {
            for status: UInt8 in 0...6 {
                let result = try XCTUnwrap(feature.decode(Data([80, 0, status, 0]), lastKnownLevel: nil))
                let expected = status == 1 || status == 2 || status == 3 || (feature == .legacy && status == 4)
                XCTAssertEqual(result.charging, expected)
                XCTAssertEqual(result.level, status == 3 ? 100 : 80)
            }
        }
        XCTAssertEqual(LogitechBatteryFeature.unified.function, 1)
        XCTAssertEqual(LogitechBatteryFeature.legacy.function, 0)
        XCTAssertFalse(LogitechBatteryFeature.allCases.map(\.rawValue).contains(0x1010))
    }

    func testUnavailableAndMalformedLevels() throws {
        let unified = LogitechBatteryFeature.unified
        XCTAssertEqual(unified.decode(Data([0, 2, 1, 0]), lastKnownLevel: nil)?.level, 20)
        XCTAssertEqual(LogitechBatteryFeature.legacy.decode(Data([0, 0, 1]), lastKnownLevel: 37)?.level, 37)
        XCTAssertNil(unified.decode(Data([255, 0, 0, 0]), lastKnownLevel: 50))
        XCTAssertNil(unified.decode(Data([50, 0]), lastKnownLevel: nil))
        XCTAssertNil(unified.decode(Data([50, 0, 255, 0]), lastKnownLevel: nil))
        XCTAssertNil(LogitechBatteryFeature.legacy.decode(Data([0, 0, 0]), lastKnownLevel: nil))
    }

    func testReplyMatchesOnlyOurRequest() throws {
        let response = LogitechReply.match(Data([0x11, 0xFF, 5, 0x1A, 37, 0, 1]), feature: 5, function: 0x1A)
        XCTAssertEqual(try XCTUnwrap(response).get(), Data([37, 0, 1]))
        XCTAssertNil(LogitechReply.match(Data([0x11, 0xFF, 5, 0x10, 80]), feature: 5, function: 0x1A))
        XCTAssertNil(LogitechReply.match(Data([0x11, 0xFF, 0xFF, 6, 0x1A, 2]), feature: 5, function: 0x1A))
        let error = LogitechReply.match(Data([0x11, 0xFF, 0xFF, 5, 0x1A, 2]), feature: 5, function: 0x1A)
        XCTAssertThrowsError(try XCTUnwrap(error).get())
        let short = LogitechReply.match(Data([0x10, 0xFF, 5, 0x1A, 1, 2, 3]), feature: 5, function: 0x1A)
        XCTAssertEqual(try XCTUnwrap(short).get(), Data([1, 2, 3]))
        let directBluetooth = LogitechReply.match(
            Data([0x11, 0x00, 5, 0x1A, 44, 0, 1]), feature: 5, function: 0x1A
        )
        XCTAssertEqual(try XCTUnwrap(directBluetooth).get(), Data([44, 0, 1]))
        XCTAssertNil(LogitechReply.match(
            Data([0x11, 0x01, 5, 0x1A, 44, 0, 1]), feature: 5, function: 0x1A
        ))
    }

    func testPartialUpdatesExpireAndDisconnectsRemoveCache() {
        let now = Date(timeIntervalSince1970: 1000)
        var cache = LogitechBatteryCache()
        cache.record([AccessoryBattery(name: "Mouse", level: 50, charging: true),
                      AccessoryBattery(name: "Keyboard", level: 80, charging: false)], at: now)
        cache.record([AccessoryBattery(name: "Keyboard", level: 79, charging: false)], at: now.addingTimeInterval(90))
        XCTAssertEqual(cache.current(at: now.addingTimeInterval(100)).count, 2)
        XCTAssertEqual(cache.current(at: now.addingTimeInterval(120)).map(\.name), ["Keyboard"])
        cache.retainVisible([])
        XCTAssertTrue(cache.current(at: now.addingTimeInterval(121)).isEmpty)
    }

    func testMXMaster2SChargingReplyWithoutPercentageIsNotDiscarded() throws {
        // Observed from the connected mouse: legacy status [0, 0, 1].
        let status = try XCTUnwrap(LogitechBatteryFeature.legacy.decodeStatus(
            Data([0, 0, 1]), lastKnownLevel: nil
        ))
        XCTAssertNil(status.level)
        XCTAssertTrue(status.charging)
        XCTAssertTrue(status.chargingKnown)
        XCTAssertFalse(status.reportsLevel)
        let cached = try XCTUnwrap(LogitechBatteryFeature.legacy.decodeStatus(
            Data([0, 0, 1]), lastKnownLevel: 44
        ))
        XCTAssertEqual(cached.level, 44)
        XCTAssertFalse(cached.reportsLevel) // Must not renew the cached percentage's timestamp.
    }

    func testChargeOnlyReplyCombinesWithBluetoothPercentageAndThenDisconnects() {
        let date = Date()
        let fallback = AccessoryBattery(name: "MX Master 2S", level: 44, charging: false,
                                        updatedAt: date.addingTimeInterval(-10), chargingKnown: false)
        var cache = LogitechChargingCache()
        cache.record([LogitechChargingReading(name: "MX Master 2S", charging: true, updatedAt: date)])
        let charging = cache.applying(to: fallback, canonicalName: "MX Master 2S", at: date)
        XCTAssertEqual(charging.level, 44)
        XCTAssertTrue(charging.charging)
        XCTAssertTrue(charging.chargingKnown)
        XCTAssertEqual(charging.updatedAt, fallback.updatedAt)
        cache.record([LogitechChargingReading(name: "MX Master 2S", charging: false,
                                              updatedAt: date.addingTimeInterval(15))])
        XCTAssertFalse(cache.applying(to: fallback, canonicalName: "MX Master 2S",
                                     at: date.addingTimeInterval(15)).charging)
        XCTAssertFalse(cache.applying(to: fallback, canonicalName: "MX Master 2S",
                                     at: date.addingTimeInterval(135)).chargingKnown)
        cache.retainVisible([])
        XCTAssertFalse(cache.applying(to: fallback, canonicalName: "MX Master 2S", at: date).chargingKnown)
    }

    func testNameMatchingDoesNotDependOnBluetoothSpacing() {
        XCTAssertEqual(LogitechReader.canonicalName(for: "MX Master 2S"), "MX Master 2S")
        XCTAssertEqual(LogitechReader.canonicalName(for: "MXMaster2S"), "MX Master 2S")
        XCTAssertNil(LogitechReader.canonicalName(for: "Unknown mouse"))
    }

    func testChargingErrorsAreNotReportedAsKnownDischarging() throws {
        XCTAssertFalse(try XCTUnwrap(LogitechBatteryFeature.unified.decodeStatus(
            Data([80, 0, 4, 0]), lastKnownLevel: nil
        )).chargingKnown)
        XCTAssertFalse(try XCTUnwrap(LogitechBatteryFeature.legacy.decodeStatus(
            Data([80, 0, 6]), lastKnownLevel: nil
        )).chargingKnown)
    }
}
