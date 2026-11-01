import AppKit
import Combine
import Foundation
import OSLog
#if canImport(Sparkle)
import Sparkle
#endif

/// The Xcode app owns one updater for its entire lifetime. SwiftPM builds do not
/// embed Sparkle and intentionally expose no updater UI.
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    @Published private(set) var availableVersion: String?
    @Published private(set) var canCheckForUpdates = false

    var isUpdateAvailable: Bool { availableVersion != nil }

    private static let logger = Logger(subsystem: "me.yura.barttery", category: "Updates")

    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    private var availabilityObservation: AnyCancellable?
    #endif

    /// Validate configuration before starting, including in unsigned/test builds.
    static func hasValidConfiguration(_ info: [String: Any]) -> Bool {
        guard info["BartterySparkleEnabled"] as? Bool == true,
              let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return false }
        return true
    }

    func start() {
        #if canImport(Sparkle)
        guard controller == nil,
              Self.hasValidConfiguration(Bundle.main.infoDictionary ?? [:]) else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self
        )
        self.controller = controller
        availabilityObservation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
        controller.startUpdater()
        #endif
    }

    func showUpdate() {
        #if canImport(Sparkle)
        guard isUpdateAvailable, canCheckForUpdates, let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        // Sparkle resumes its deferred update session, rather than starting a
        // separate downloader or opening a browser.
        controller.checkForUpdates(nil)
        #endif
    }

    func recordAvailableUpdate(version: String) {
        guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        availableVersion = version
    }

    func handleUpdatePresentation(willShowDialog: Bool, version: String) {
        // A scheduled update is deferred to our row. User-initiated updates
        // already have a Sparkle window and do not need a second reminder.
        if !willShowDialog { recordAvailableUpdate(version: version) }
    }

    func clearUpdateReminder() {
        availableVersion = nil
    }
}

#if canImport(Sparkle)
extension AppUpdater: SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Always defer scheduled alerts, including immediately after launch.
        // Our menu row is the only background update reminder.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        handleUpdatePresentation(willShowDialog: handleShowingUpdate,
                                 version: update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        clearUpdateReminder()
    }

    func standardUserDriverWillFinishUpdateSession() {
        clearUpdateReminder()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        clearUpdateReminder()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        clearUpdateReminder()
        // Background failures stay out of the user's way; no notification or
        // "update available" row is fabricated when the feed cannot be fetched.
        Self.logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
    }
}
#endif
