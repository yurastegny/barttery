import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var widgetPublisher: WidgetSnapshotPublisher?

    func connectWidgets(to monitor: DeviceBatteryMonitor) {
        guard widgetPublisher == nil else { return }
        widgetPublisher = WidgetSnapshotPublisher(monitor: monitor)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppUpdater.shared.start()
    }
}

@main
struct BartteryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = DeviceBatteryMonitor()

    init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NotificationManager.shared.requestPermission()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(monitor)
                .onAppear { monitor.onPopupOpen() }
                .onDisappear { monitor.onPopupClose() }
        } label: {
            MenuBarLabel(monitor: monitor)
                .onAppear { appDelegate.connectWidgets(to: monitor) }
        }
        .menuBarExtraStyle(.window)
    }
}
