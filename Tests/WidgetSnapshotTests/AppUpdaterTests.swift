import XCTest
@testable import Barttery

final class AppUpdaterTests: XCTestCase {
    func testReminderIsHiddenUntilAnUpdateIsAvailable() {
        let updater = AppUpdater()
        XCTAssertFalse(updater.isUpdateAvailable)
        XCTAssertFalse(updater.canCheckForUpdates)
        updater.recordAvailableUpdate(version: "1.2.2")
        XCTAssertTrue(updater.isUpdateAvailable)
        XCTAssertEqual(updater.availableVersion, "1.2.2")
    }

    func testDismissedAndFinishedUpdatesClearReminder() {
        let updater = AppUpdater()
        updater.recordAvailableUpdate(version: "1.2.2")
        updater.clearUpdateReminder()
        XCTAssertFalse(updater.isUpdateAvailable)
        XCTAssertNil(updater.availableVersion)
        updater.recordAvailableUpdate(version: "1.2.3")
        XCTAssertEqual(updater.availableVersion, "1.2.3")
    }

    func testEmptyVersionDoesNotShowReminder() {
        let updater = AppUpdater()
        updater.recordAvailableUpdate(version: " \n")
        XCTAssertFalse(updater.isUpdateAvailable)
    }

    func testOnlyDeferredUpdatesCreateMenuReminder() {
        let updater = AppUpdater()
        updater.handleUpdatePresentation(willShowDialog: true, version: "1.2.2")
        XCTAssertFalse(updater.isUpdateAvailable)
        updater.handleUpdatePresentation(willShowDialog: false, version: "1.2.2")
        XCTAssertTrue(updater.isUpdateAvailable)
        XCTAssertEqual(updater.availableVersion, "1.2.2")
    }

    func testConfigurationRequiresEnabledHTTPSFeedAndEd25519PublicKey() {
        var info: [String: Any] = [
            "BartterySparkleEnabled": true,
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()
        ]
        XCTAssertTrue(AppUpdater.hasValidConfiguration(info))
        info["SUFeedURL"] = "http://example.com/appcast.xml"
        XCTAssertFalse(AppUpdater.hasValidConfiguration(info))
        info["SUFeedURL"] = "https://example.com/appcast.xml"
        info["SUPublicEDKey"] = "invalid"
        XCTAssertFalse(AppUpdater.hasValidConfiguration(info))
        info["SUPublicEDKey"] = Data(repeating: 1, count: 32).base64EncodedString()
        info["BartterySparkleEnabled"] = false
        XCTAssertFalse(AppUpdater.hasValidConfiguration(info))
        XCTAssertFalse(AppUpdater.hasValidConfiguration([:]))
    }
}
