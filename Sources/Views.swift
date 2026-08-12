import SwiftUI
import AppKit

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

    @State private var windowTimer: Timer?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Barttery")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.secondary)
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
                // MacBook
                if let mac = monitor.macBattery {
                    DeviceRow(
                        icon: "􁈸",
                        name: monitor.macName,
                        battery: mac.level,
                        state: mac.state,
                        device: .mac
                    )
                }

                // AirPods
                if let pods = monitor.airPodsBattery {
                    AirPodsRow(
                        name: monitor.airPodsName,
                        battery: pods
                    )
                }

                // Accessories (Magic Keyboard, Mouse, Trackpad)
                ForEach(monitor.accessories, id: \.name) { acc in
                    AccessoryRow(accessory: acc)
                }

                // iPhone
                if let pct = monitor.phoneBattery {
                    DeviceRow(
                        icon: "􀟜",
                        name: monitor.phoneName,
                        battery: pct,
                        state: monitor.phoneCharging ? .charging : .discharging,
                        device: .phone
                    )
                }

                // iPad
                if let pct = monitor.padBattery {
                    DeviceRow(
                        icon: "􀟠",
                        name: monitor.padName,
                        battery: pct,
                        state: monitor.padCharging ? .charging : .discharging,
                        device: .pad
                    )
                }

                // Apple Watch
                if let watch = monitor.watchBattery {
                    DeviceRow(
                        icon: "􀟤",
                        name: watch.name,
                        battery: watch.level,
                        state: watch.isCharging ? .charging : .discharging,
                        device: .watch
                    )
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
        .frame(width: 360)
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
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            }

            if expanded {
                NotificationThresholdRow(device: device)
                    .padding(.leading, 38)
                        .padding(.top, -2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
            if let level = podsLevel {
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
                                    Text("\(level)%").font(.system(size: 17, weight: .regular))
                                }
                            }
                            BatteryBar(level: level).frame(height: 1)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    }

                    if expanded {
                        NotificationThresholdRow(device: .airPods)
                            .padding(.leading, 38)
                        .padding(.top, -2)
                            .transition(.opacity.combined(with: .move(edge: .top)))
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

    private var podsLevel: Int? {
        [battery.left, battery.right].compactMap { $0 }.min()
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
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            }

            if expanded {
                NotificationThresholdRow(device: accessory.batteryDevice)
                    .padding(.leading, 38)
                        .padding(.top, -2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
                    Text(date, style: .relative)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 6) {
                ForEach(device == .airPods ? [20] : [20, 80, 100], id: \.self) { threshold in
                    ThresholdToggleButton(
                        label: threshold == 20 ? "↓20%" : threshold == 80 ? "↑80%" : "100%",
                        enabled: settings.isThresholdEnabled(device: device, threshold: threshold)
                    ) {
                        settings.toggleThreshold(device: device, threshold: threshold)
                    }
                }
            }
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
    @Environment(\.colorScheme) var colorScheme

    func makeBody(configuration: Configuration) -> some View {
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


// MARK: - Helpers

private func formatMinutes(_ minutes: Int) -> String {
    let h = minutes / 60
    let m = minutes % 60
    return h > 0 ? "\(h):\(String(format: "%02d", m))" : "0:\(String(format: "%02d", m))"
}

private func batteryColor(_ level: Int) -> Color {
    switch level {
    case 0...20: return .red
    case 21...40: return .orange
    default:      return .green
    }
}
