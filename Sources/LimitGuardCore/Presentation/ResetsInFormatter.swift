import Foundation

/// The time left until a limit window resets, as the popover shows it: "3 h 42 m", "5 d 21 h", "42 m".
public enum ResetsInFormatter {
    /// Uses the string table of `locale`'s language. A part of a minute counts as a whole one, so
    /// "0 m" never shows while time is left; a date that has passed gives "< 1 m".
    public static func string(until date: Date, now: Date, locale: Locale) -> String {
        Localization.$bundle.withValue(Localization.table(for: locale)) {
            text(seconds: date.timeIntervalSince(now))
        }
    }

    static func text(seconds: TimeInterval) -> String {
        let totalMinutes = seconds > 0 ? Int((seconds / 60).rounded(.up)) : 0
        let days = totalMinutes / 1440
        let hours = totalMinutes % 1440 / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return Localization.format("resetsIn.daysHours", "%1$ld d %2$ld h", days, hours)
        }
        if hours > 0 {
            return Localization.format("resetsIn.hoursMinutes", "%1$ld h %2$ld m", hours, minutes)
        }
        if minutes > 0 {
            return Localization.format("resetsIn.minutes", "%ld m", minutes)
        }
        return Localization.string("resetsIn.lessThanAMinute", "< 1 m")
    }
}
