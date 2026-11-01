import AppKit
import Sparkle

// Compile together with Sources/AppUpdater.swift against the actual framework:
// swiftc -F .build/sparkle-tools -framework Sparkle \
//   -Xlinker -rpath -Xlinker "$PWD/.build/sparkle-tools" \
//   Sources/AppUpdater.swift Tests/SparkleIntegrationSmoke.swift \
//   -o .build/sparkle-reminder-smoke
// Does not start the updater, contact the feed, or install an application.
@main
struct SparkleIntegrationSmoke {
    static func main() {
        let updater = AppUpdater()
        let item = SUAppcastItem.empty()
        precondition(updater.supportsGentleScheduledUpdateReminders)
        precondition(!updater.standardUserDriverShouldHandleShowingScheduledUpdate(
            item, andInImmediateFocus: false
        ))
        precondition(!updater.standardUserDriverShouldHandleShowingScheduledUpdate(
            item, andInImmediateFocus: true
        ))
        precondition(!updater.isUpdateAvailable)
        updater.handleUpdatePresentation(willShowDialog: false, version: "1.2.2")
        precondition(updater.isUpdateAvailable)
        updater.standardUserDriverDidReceiveUserAttention(forUpdate: item)
        precondition(!updater.isUpdateAvailable)
        updater.recordAvailableUpdate(version: "1.2.2")
        updater.standardUserDriverWillFinishUpdateSession()
        precondition(!updater.isUpdateAvailable)
        print("Sparkle delegate smoke checks passed (no network or installation).")
    }
}
