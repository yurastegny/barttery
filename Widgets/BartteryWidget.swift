import SwiftUI
import WidgetKit

struct BatteryEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetBatterySnapshot
}

struct BatteryTimelineProvider: TimelineProvider {
    var layout: WidgetBatteryLayout = .fourWide

    func placeholder(in context: Context) -> BatteryEntry {
        BatteryEntry(date: Date(), snapshot: .placeholder(layout: layout))
    }

    func getSnapshot(in context: Context, completion: @escaping (BatteryEntry) -> Void) {
        completion(BatteryEntry(date: Date(), snapshot: context.isPreview ? .placeholder(layout: layout) : WidgetSnapshotStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BatteryEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshotStore.read()
        // Pre-schedule freshness transitions even if the host app stops running.
        let expiryDates = Set(snapshot.displayedDevices(for: layout).map {
            $0.updatedAt.addingTimeInterval(WidgetBatterySnapshot.staleInterval)
        }.filter { $0 > now }).sorted()
        let entries = [BatteryEntry(date: now, snapshot: snapshot)] + expiryDates.map {
            BatteryEntry(date: $0, snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

struct BatteryWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: BatteryEntry
    var layout: WidgetBatteryLayout = .fourWide
    // WidgetKit supplies this read-only environment value; offscreen previews cannot set it.
    var previewFamily: WidgetFamily? = nil

    private var devices: [WidgetBatteryDevice] {
        let limit = layout == .table && (previewFamily ?? family) != .systemLarge ? 4 : layout.capacity
        return Array(entry.snapshot.displayedDevices(for: layout).prefix(limit))
    }
    private var hasStaleData: Bool { devices.contains { $0.isStale(at: entry.date) } }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.isCompact ? 6 : 8) {
            HStack {
                Text("Batteries").font(layout.isCompact ? .caption.weight(.semibold) : .headline)
                Spacer()
                if hasStaleData && layout != .fourWide {
                    Image(systemName: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Data may be out of date")
                } else if layout == .fourWide || layout == .table {
                    Text("Barttery").font(.caption).foregroundStyle(.secondary)
                }
            }

            if devices.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "battery.100percent").font(.title2)
                    Text("Open Barttery to see your devices")
                        .font(.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if layout == .table {
                VStack(spacing: 0) {
                    ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                        BatteryTableRow(device: device, date: entry.date)
                            .frame(maxHeight: .infinity)
                        if index < devices.count - 1 {
                            Divider().opacity(0.4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let rows = layout.capacity / layout.columns
                    let rowHeight = (geometry.size.height - CGFloat(rows - 1) * 6) / CGFloat(rows)
                    let columnWidth = (geometry.size.width - CGFloat(layout.columns - 1) * 8) / CGFloat(layout.columns)
                    let labelHeight: CGFloat = layout.isCompact ? 14 : (layout == .single ? 42 : 38)
                    let ringSize = max(16, min(layout == .single ? 72 : (layout.isCompact ? 36 : 50),
                                               min(rowHeight - labelHeight, columnWidth - 8)))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: layout.columns), spacing: 6) {
                        ForEach(0..<layout.capacity, id: \.self) { index in
                            if index < devices.count {
                                BatteryRing(device: devices[index], date: entry.date,
                                            size: ringSize, compact: layout.isCompact,
                                            single: layout == .single)
                                    .frame(height: rowHeight)
                            } else {
                                VStack {
                                    Circle().stroke(.secondary.opacity(0.12), lineWidth: layout.isCompact ? 3 : 5)
                                        .frame(width: ringSize, height: ringSize)
                                    Spacer(minLength: 0)
                                }
                                .padding(.top, 3)
                                .frame(maxWidth: .infinity)
                                .frame(height: rowHeight)
                                .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }

            if hasStaleData && layout == .fourWide {
                Label("Data may be out of date · Open Barttery", systemImage: "clock")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if devices.isEmpty && (layout == .fourWide || layout == .table) {
                Text("Keep Barttery running to update batteries")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }
}

private struct BatteryTableRow: View {
    let device: WidgetBatteryDevice
    let date: Date

    private var stale: Bool { device.isStale(at: date) }
    private var tint: Color {
        if stale { return .secondary }
        return device.level <= 20 && !device.isCharging ? .red : .green
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 22)
            Text(device.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: device.statusSymbol ?? "clock")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .opacity(device.statusSymbol != nil || stale ? 1 : 0)
                .frame(width: 14)
            Text("\(device.level)%")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .frame(width: 43, alignment: .trailing)
        }
        .foregroundStyle(stale ? .secondary : .primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.name), \(device.level)%")
        .accessibilityValue(stale ? "Out of date" : device.statusDescription)
    }
}

private struct BatteryRing: View {
    let device: WidgetBatteryDevice
    let date: Date
    var size: CGFloat = 50
    var compact: Bool = false
    var single: Bool = false

    private var lineWidth: CGFloat { compact ? 3 : 5 }

    private var stale: Bool { device.isStale(at: date) }
    private var tint: Color {
        if stale { return .secondary }
        return device.level <= 20 && !device.isCharging ? .red : .green
    }

    var body: some View {
        VStack(spacing: compact ? 2 : 4) {
            ZStack {
                Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: CGFloat(min(100, max(0, device.level))) / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: device.symbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(stale ? .secondary : .primary)
            }
            .frame(width: size, height: size)
            VStack(spacing: 0) {
                HStack(spacing: 3) {
                    Text("\(device.level)%")
                        .font(.system(size: compact ? 11 : (single ? 20 : 14), weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    // Standalone glyphs survive glass/tinted rendering without a badge background.
                    if let statusSymbol = device.statusSymbol {
                        Image(systemName: statusSymbol)
                            .font(.system(size: compact ? 9 : (single ? 14 : 11), weight: .bold))
                            .foregroundStyle(tint)
                    }
                }
                if !compact {
                    Text(device.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.name), \(device.level)%")
        .accessibilityValue(stale ? "Out of date" : device.statusDescription)
    }

}

#if !WIDGET_RENDER
@main
struct BartteryWidgets: WidgetBundle {
    var body: some Widget {
        BartteryWidget()
        SingleBatteryWidget()
        FourSquareBatteryWidget()
        TableBatteryWidget()
    }
}

struct BartteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotStore.widgetKind, provider: BatteryTimelineProvider()) { entry in
            BatteryWidgetView(entry: entry)
        }
        .configurationDisplayName("Batteries")
        .description("Battery levels for up to four of your devices. Keep Barttery running for fresh readings.")
        .supportedFamilies([.systemMedium])
    }
}

struct SingleBatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetBatteryLayout.single.widgetKind, provider: BatteryTimelineProvider(layout: .single)) { entry in
            BatteryWidgetView(entry: entry, layout: .single)
        }
        .configurationDisplayName("Battery · 1 device")
        .description("One device with a large battery ring. Keep Barttery running for fresh readings.")
        .supportedFamilies([.systemSmall])
    }
}

struct FourSquareBatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetBatteryLayout.fourSquare.widgetKind, provider: BatteryTimelineProvider(layout: .fourSquare)) { entry in
            BatteryWidgetView(entry: entry, layout: .fourSquare)
        }
        .configurationDisplayName("Batteries · 4 devices")
        .description("Four battery rings in a compact square. Keep Barttery running for fresh readings.")
        .supportedFamilies([.systemSmall])
    }
}

struct TableBatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetBatteryLayout.table.widgetKind, provider: BatteryTimelineProvider(layout: .table)) { entry in
            BatteryWidgetView(entry: entry, layout: .table)
        }
        .configurationDisplayName("Batteries · Table")
        .description("Device names, battery levels, and charging status in rows. Up to four devices in medium size or eight in large size.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct BartteryWidgetPreviews: PreviewProvider {
    static var previews: some View {
        BatteryWidgetView(entry: BatteryEntry(date: Date(), snapshot: .placeholder()))
            .previewContext(WidgetPreviewContext(family: .systemMedium))
    }
}
#endif
