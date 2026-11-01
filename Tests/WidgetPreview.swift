// Optional offscreen visual smoke test; see `make widget-preview`.
import AppKit
import SwiftUI
import WidgetKit

@main
struct WidgetPreview {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let now = Date()
        let fresh = WidgetBatterySnapshot.placeholder(at: now)
        let pausedDevices = fresh.devices.map { device in
            WidgetBatteryDevice(id: device.id, name: device.name, symbol: device.symbol,
                                level: device.id == "mac" ? 80 : device.level,
                                isCharging: device.id == "mac" ? false : device.isCharging,
                                isPaused: device.id == "mac", updatedAt: device.updatedAt)
        }
        let paused = WidgetBatterySnapshot(devices: pausedDevices, writtenAt: now)
        let eight = WidgetBatterySnapshot(devices: fresh.devices + [
            WidgetBatteryDevice(id: "pad", name: "iPad", symbol: "ipad", level: 20, isCharging: false, updatedAt: now),
            WidgetBatteryDevice(id: "keyboard", name: "Magic Keyboard", symbol: "keyboard", level: 76, isCharging: false, updatedAt: now),
            WidgetBatteryDevice(id: "mouse", name: "MX Master", symbol: "computermouse", level: 15, isCharging: true, updatedAt: now),
            WidgetBatteryDevice(id: "case", name: "AirPods Case", symbol: "airpods.chargingcase", level: 92, isCharging: false, updatedAt: now)
        ], writtenAt: now)
        let stale = WidgetBatterySnapshot.placeholder(at: now.addingTimeInterval(-3600))
        let previews = VStack(spacing: 16) {
            HStack(spacing: 20) {
                preview(paused, at: now, layout: .single)
                    .environment(\.widgetRenderingMode, .accented)
                preview(fresh, at: now, layout: .fourSquare)
                    .environment(\.widgetRenderingMode, .vibrant)
            }
            HStack(spacing: 20) {
                preview(paused, at: now, layout: .single)
                preview(fresh, at: now, layout: .fourSquare)
            }
            preview(paused, at: now, layout: .table)
            preview(eight, at: now, layout: .table, family: .systemLarge)
            preview(stale, at: now, layout: .table)
                .environment(\.widgetRenderingMode, .accented)
            preview(.empty, at: now, layout: .table)
            preview(fresh, at: now)
            preview(paused, at: now)
            preview(stale, at: now)
            preview(.empty, at: now)
        }
        .padding(20)
        .background(Color.gray.opacity(0.2))
        let renderer = ImageRenderer(content: previews)
        renderer.scale = 2
        guard let image = renderer.cgImage else { fatalError("Unable to render widget previews") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Unable to encode PNG") }
        try png.write(to: URL(fileURLWithPath: ".build/widget-preview.png"))
    }

    @MainActor
    static func preview(_ snapshot: WidgetBatterySnapshot, at date: Date,
                        layout: WidgetBatteryLayout = .fourWide, family: WidgetFamily = .systemMedium) -> some View {
        BatteryWidgetView(entry: BatteryEntry(date: date, snapshot: snapshot), layout: layout, previewFamily: family)
            .padding(16)
            .frame(width: layout == .single || layout == .fourSquare ? 170 : 360,
                   height: family == .systemLarge ? 360 : 170)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
    }
}
