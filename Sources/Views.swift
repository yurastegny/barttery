import SwiftUI
import AppKit

private let popupExpandAnimation: Animation = .easeInOut(duration: 0.2)
private let popupCornerRadius: CGFloat = 14

private struct RefreshButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(configuration.isPressed ? .primary : .secondary)
    }
}

// MARK: - Menu bar icon

struct MenuBarLabel: View {
    @ObservedObject var monitor: DeviceBatteryMonitor

    var body: some View {
        Image(nsImage: monitor.menuBarIcon)
            .renderingMode(.template)
            .interpolation(.high)
            .antialiased(true)
            .frame(maxHeight: .infinity)
    }
}

// MARK: - Popup window

struct MenuContentView: View {
    @EnvironmentObject var monitor: DeviceBatteryMonitor
    @ObservedObject private var settings = AppSettings.shared
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let fitted = contentHeight > 1 ? min(contentHeight, Self.maxPopupHeight) : nil
        let scrolling = fitted.map { contentHeight > $0 + 1 } ?? false

        ScrollView(.vertical, showsIndicators: scrolling) {
            menuStack
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: MenuContentHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
        }
        .scrollContentBackground(.hidden)
        .frame(width: 360, alignment: .top)
        .frame(height: fitted, alignment: .top)
        .onPreferenceChange(MenuContentHeightKey.self) { newValue in
            guard abs(newValue - contentHeight) > 0.5 else { return }
            if contentHeight <= 1 {
                contentHeight = newValue
            } else {
                withAnimation(popupExpandAnimation) { contentHeight = newValue }
            }
        }
        .background(MenuBarWindowHeightAnimator(height: fitted ?? 0))
        .modifier(PopupGlassBackground())
    }

    private static var maxPopupHeight: CGFloat {
        guard let screen = NSScreen.main else { return 800 }
        return max(240, screen.visibleFrame.height - 12)
    }

    private var menuStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/yurastegny/barttery")!)
                } label: {
                    Text("Barttery")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    monitor.refresh()
                } label: {
                    Text("Refresh")
                        .font(.system(size: 14, weight: .regular))
                }
                .buttonStyle(RefreshButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            VStack(spacing: 18) {
                if let mac = monitor.macBattery {
                    DeviceRow(icon: "􁈸", name: monitor.macName,
                              battery: mac.level, state: mac.state, device: .mac)
                }
                if let pods = monitor.airPodsBattery {
                    AirPodsRow(name: monitor.airPodsName, battery: pods)
                }
                ForEach(monitor.accessories, id: \.name) { acc in
                    AccessoryRow(accessory: acc)
                }
                if let pct = monitor.phoneBattery {
                    DeviceRow(icon: "􀟜", name: monitor.phoneName,
                              battery: pct, state: monitor.phoneCharging ? .charging : .discharging, device: .phone)
                }
                if let pct = monitor.padBattery {
                    DeviceRow(icon: "􀟠", name: monitor.padName,
                              battery: pct, state: monitor.padCharging ? .charging : .discharging, device: .pad)
                }
                if let watch = monitor.watchBattery {
                    DeviceRow(icon: "􀟤", name: watch.name,
                              battery: watch.level, state: watch.isCharging ? .charging : .discharging, device: .watch)
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)

            Button {
                settings.launchAtLogin.toggle()
            } label: {
                HStack {
                    Text("Launch at Login")
                    Spacer()
                    if settings.launchAtLogin {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .regular))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().padding(.horizontal, 16)

            HStack(alignment: .center) {
                if let cycles = monitor.macBattery?.cycleCount, cycles > 0 {
                    Text("MacBook: \(cycles) cycles")
                        .foregroundColor(.secondary)
                        .offset(y: -1)
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 14, weight: .regular))
                .offset(y: -1)
            }
            .font(.system(size: 14, weight: .regular))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

}

private struct MenuContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MenuBarWindowHeightAnimator: View, Animatable {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    var body: some View {
        MenuBarWindowHeightSync(contentHeight: height)
    }
}

private struct PopupGlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                )
                .containerBackground(.clear, for: .window)
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                }
                .clipShape(RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous))
        }
    }
}

private struct MenuBarWindowHeightSync: NSViewRepresentable {
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            return view
        } else {
            let effect = NSVisualEffectView()
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            return effect
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let apply = {
            Self.prepareWindow(nsView.window)
            Self.resize(window: nsView.window, contentHeight: contentHeight)
        }
        if nsView.window == nil {
            DispatchQueue.main.async(execute: apply)
        } else {
            apply()
        }
    }

    private static func prepareWindow(_ window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        window.invalidateShadow()
    }

    private static func resize(window: NSWindow?, contentHeight: CGFloat) {
        guard let window, let contentView = window.contentView, contentHeight > 1 else { return }
        let top = window.frame.maxY
        let screenMinY = (window.screen ?? NSScreen.main)?.visibleFrame.minY ?? 0
        let chrome = window.frame.height - contentView.frame.height
        let capped = min(
            contentHeight + chrome,
            max(120, top - screenMinY)
        )
        guard abs(capped - window.frame.height) > 0.05 else { return }
        var frame = window.frame
        frame.size.height = capped
        frame.origin.y = top - capped
        window.setFrame(frame, display: true, animate: false)
    }
}

// MARK: - Device row

struct DeviceRow: View {
    let icon: String
    let name: String
    let battery: Int
    let state: ChargeState
    let device: BatteryDevice

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(.primary)
                    .frame(width: 26, alignment: .center)
                    .offset(y: 1.5)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(name).font(.system(size: 17, weight: .regular))
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: chargeIcon ?? "bolt.fill")
                                .font(.system(size: 12, weight: .medium))
                                .opacity(chargeIcon != nil ? 1 : 0)
                            Text("\(battery)%").font(.system(size: 17, weight: .regular))
                        }
                    }
                    BatteryBar(level: battery).frame(height: 1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(popupExpandAnimation) { expanded.toggle() }
            }

            if expanded {
                NotificationThresholdRow(device: device)
                    .padding(.leading, 38)
                    .padding(.top, -2)
                    .transition(.opacity)
            }
        }
    }

    private var chargeIcon: String? {
        switch state {
        case .charging:     return "bolt.fill"
        case .plugged:      return "powerplug.fill"
        case .paused:       return "pause.fill"
        case .discharging:  return nil
        }
    }

}

// MARK: - Battery bar

struct BatteryBar: View {
    let level: Int

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.2))
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(6, geo.size.width * CGFloat(level) / 100))
                }
            }
    }

    private var barColor: Color {
        let color = batteryColor(level)
        return level > 40 && colorScheme == .dark ? color.opacity(0.65) : color
    }
}

// MARK: - AirPods row

struct AirPodsRow: View {
    let name: String
    let battery: AirPodsBattery

    @State private var expanded = false

    var body: some View {
        VStack(spacing: 18) {
            if let barLevel = podsBarLevel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("􀪷")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundColor(.primary)
                            .frame(width: 26, height: 20, alignment: .center)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(name).font(.system(size: 17, weight: .regular))
                                Spacer()
                                HStack(spacing: 6) {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 12, weight: .medium))
                                        .opacity(battery.leftCharging || battery.rightCharging ? 1 : 0)
                                    Text(podsLevelText).font(.system(size: 17, weight: .regular))
                                }
                            }
                            BatteryBar(level: barLevel).frame(height: 1)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(popupExpandAnimation) { expanded.toggle() }
                    }

                    if expanded {
                        NotificationThresholdRow(device: .airPods)
                            .padding(.leading, 38)
                            .padding(.top, -2)
                            .transition(.opacity)
                    }
                }
            }

            if let caseLevel = battery.case {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("􀹫")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(.primary)
                        .frame(width: 26, height: 20, alignment: .center)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(name) Case").font(.system(size: 17, weight: .regular))
                            Spacer()
                            HStack(spacing: 6) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .opacity(battery.caseCharging ? 1 : 0)
                                Text("\(caseLevel)%").font(.system(size: 17, weight: .regular))
                            }
                        }
                        BatteryBar(level: caseLevel).frame(height: 1)
                    }
                }
            }
        }
    }

    private var isPro: Bool { name.lowercased().contains("pro") }

    private var podsBarLevel: Int? {
        [battery.left, battery.right].compactMap { $0 }.min()
    }

    private var podsLevelText: String {
        switch (battery.left, battery.right) {
        case (let l?, let r?) where l != r: return "L\(l)%  R\(r)%"
        case (let l?, _):                   return "\(l)%"
        case (_, let r?):                   return "\(r)%"
        default:                            return ""
        }
    }
}

// MARK: - Accessory row (keyboard / mouse / trackpad)

struct AccessoryRow: View {
    let accessory: AccessoryBattery

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Group {
                    if let ch = accessory.iconChar {
                        Text(ch)
                    } else {
                        Image(systemName: accessory.icon)
                    }
                }
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(.primary)
                .frame(width: 26, height: 20, alignment: .center)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(accessory.name).font(.system(size: 17, weight: .regular))
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 12, weight: .medium))
                                .opacity(accessory.charging ? 1 : 0)
                            Text("\(accessory.level)%").font(.system(size: 17, weight: .regular))
                        }
                    }
                    BatteryBar(level: accessory.level).frame(height: 1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(popupExpandAnimation) { expanded.toggle() }
            }

            if expanded {
                NotificationThresholdRow(device: accessory.batteryDevice)
                    .padding(.leading, 38)
                    .padding(.top, -2)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Notification threshold row

struct NotificationThresholdRow: View {
    let device: BatteryDevice
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var monitor: DeviceBatteryMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Notifications")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                if device == .mac, let mac = monitor.macBattery {
                    if let mins = mac.minutesToFull {
                        Text("\(formatMinutes(mins)) to full")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else if let mins = mac.minutesToEmpty {
                        Text("\(formatMinutes(mins)) remaining")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else if mac.state == .charging || mac.state == .discharging {
                        Text("Calculating…")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                } else if let date = monitor.syncTimes[device.rawValue] {
                    Text(syncElapsed(date))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 6) {
                ForEach((device == .airPods || device == .headphones) ? [20] : [20, 80, 100], id: \.self) { threshold in
                    ThresholdToggleButton(
                        label: threshold == 20 ? "↓20%" : threshold == 80 ? "↑80%" : "100%",
                        enabled: settings.isThresholdEnabled(device: device, threshold: threshold)
                    ) {
                        settings.toggleThreshold(device: device, threshold: threshold)
                    }
                }
            }
        }
        .modifier(IsolatedGeometry())
    }
}

private struct IsolatedGeometry: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.geometryGroup()
        } else {
            content
        }
    }
}

// MARK: - Threshold toggle button

struct ThresholdToggleButton: View {
    let label: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15))
                .foregroundColor(.primary)
                .frame(width: 56, height: 22)
        }
        .buttonStyle(ThresholdButtonStyle(enabled: enabled))
    }
}

struct ThresholdButtonStyle: ButtonStyle {
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        ThresholdButtonBody(configuration: configuration, enabled: enabled)
    }
}

private struct ThresholdButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let enabled: Bool
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        if #available(macOS 26, *) {
            if enabled {
                configuration.label
                    .scaleEffect(configuration.isPressed ? 0.94 : 1)
                    .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                    .background {
                        Color.clear
                            .glassEffect(
                                .regular.interactive(),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
            } else {
                configuration.label
                    .opacity(0.4)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
            }
        } else {
            configuration.label
                .background(enabled && colorScheme == .light ? Color.white : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            enabled && colorScheme == .dark
                                ? Color.white
                                : enabled ? Color.primary : Color.primary.opacity(0.2),
                            lineWidth: enabled && colorScheme == .dark ? 0.75 : 0.5
                        )
                )
                .contentShape(Rectangle())
        }
    }
}


// MARK: - Helpers

private func syncElapsed(_ date: Date) -> String {
    let mins = max(1, Int(Date().timeIntervalSince(date) / 60))
    return "\(mins) min ago"
}

private func formatMinutes(_ minutes: Int) -> String {
    if minutes <= 1 { return "1 min" }
    let h = minutes / 60
    let m = minutes % 60
    return h > 0 ? "\(h):\(String(format: "%02d", m))" : "0:\(String(format: "%02d", m))"
}

private extension Color {
    init(hex: UInt32) {
        self.init(red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >>  8) & 0xFF) / 255,
                  blue:  Double( hex        & 0xFF) / 255)
    }
}

private func batteryColor(_ level: Int) -> Color {
    switch level {
    case 0...20: return .red
    case 21...40: return .orange
    default:      return Color(hex: 0x57A269)
    }
}
