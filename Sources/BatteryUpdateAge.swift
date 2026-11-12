import Foundation

enum BatteryUpdateAge {
    static func text(since date: Date?, at now: Date = Date()) -> String {
        guard let date else { return "Not updated yet" }
        let elapsed = now.timeIntervalSince(date)
        // Sentinel/malformed dates and clock changes must not turn into enormous
        // counters or overflow an Int. They do not mean a successful fresh read.
        guard date > .distantPast, elapsed.isFinite, elapsed >= -60 else { return "Unknown" }
        let seconds = max(0, elapsed)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h ago" }
        if seconds < 30 * 86400 { return "\(Int(seconds / 86400)) d ago" }
        return "Over 30 days ago"
    }
}
