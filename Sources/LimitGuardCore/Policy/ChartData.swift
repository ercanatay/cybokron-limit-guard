import Foundation

/// Pure shaping of the usage chart's data (spec §12).
public enum ChartData {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// The `days` days ending on `today` ("yyyy-MM-dd"), oldest first, from the report's daily
    /// buckets; days the report has no bucket for count 0. Empty when there are no buckets at all
    /// or `today` isn't a valid day.
    public static func daily(_ report: UsageReport, days: Int, today: String) -> [DailyUsage] {
        guard let buckets = report.daily, days > 0 else { return [] }
        let f = formatter()
        guard let end = f.date(from: today) else { return [] }
        var tokensByDay: [String: Int64] = [:]
        for bucket in buckets { tokensByDay[bucket.day, default: 0] += bucket.tokens }
        return (0..<days).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: end) else { return nil }
            let day = f.string(from: date)
            return DailyUsage(day: day, tokens: tokensByDay[day] ?? 0)
        }
    }

    /// The samples of the last `days` days, relative to `now` (the newest sample when nil).
    public static func limitHistory(_ samples: [UsageSample], days: Int, now: Date? = nil) -> [UsageSample] {
        guard let anchor = now ?? samples.map(\.date).max() else { return [] }
        let cutoff = anchor.addingTimeInterval(-Double(days) * 24 * 3600)
        return samples.filter { $0.date >= cutoff && $0.date <= anchor }.sorted { $0.date < $1.date }
    }

    /// Token counts as "950", "1.5 K", "248 M", "1.2 B".
    public static func compactTokens(_ value: Int64) -> String {
        let magnitude = Double(abs(value))
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        guard let unit = units.first(where: { magnitude >= $0.0 }) else { return String(value) }
        let scaled = Double(value) / unit.0
        let text = abs(scaled) < 10 ? String(format: "%.1f", scaled) : String(format: "%.0f", scaled)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + " " + unit.1
    }
}
