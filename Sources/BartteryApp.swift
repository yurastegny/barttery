import SwiftUI
import AppKit

@main
struct BartteryApp: App {
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
