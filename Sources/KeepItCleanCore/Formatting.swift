import Foundation

public enum KeepFormatting {
    public static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        if unit == 0 { return "\(value) B" }
        return String(format: amount >= 10 ? "%.1f %@" : "%.2f %@", amount, units[unit])
    }

    public static func age(since date: Date, now: Date = Date()) -> String {
        let days = max(0, Int(now.timeIntervalSince(date) / 86_400))
        if days == 0 { return "today" }
        if days == 1 { return "1 day" }
        return "\(days) days"
    }
}
