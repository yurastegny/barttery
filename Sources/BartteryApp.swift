import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct BartteryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = DeviceBatteryMonitor()

    init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NotificationManager.shared.requestPermission()
            UpdateChecker.checkIfNeeded()
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
        }
        .menuBarExtraStyle(.window)
    }
}
