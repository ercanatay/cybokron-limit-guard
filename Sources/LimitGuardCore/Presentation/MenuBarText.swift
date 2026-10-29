import Foundation

/// The text next to the menu-bar icon (spec §4.1): the window with the higher `usedPercent`, as
/// `5h 100%` or `W 97%`, and how alarming it is.
public enum MenuBarText {
    public enum Level: Equatable, Sendable {
        case normal
        /// ≥ 80 % used: orange.
        case warning
        /// ≥ 95 % used, or ordinary use not allowed: red.
        case critical
    }

    static let warningPercent = 80.0
    static let criticalPercent = 95.0

    /// `text` is nil when `showPercent` is off or there is no window to show; `level` is worked out
    /// either way. Equal percentages show the 5-hour window.
    public static func make(snapshot: AccountSnapshot?, showPercent: Bool) -> (text: String?, level: Level) {
        guard let snapshot else { return (nil, .normal) }
        let windows: [(label: String, window: RateLimitWindow)] = [
            snapshot.fiveHour.map { ("5h", $0) },
            snapshot.weekly.map { ("W", $0) },
        ].compactMap { $0 }
        var shown = windows.first
        for candidate in windows.dropFirst() where candidate.window.usedPercent > (shown?.window.usedPercent ?? -1) {
            shown = candidate
        }
        let shownLevel = level(usedPercent: shown?.window.usedPercent ?? 0, ordinaryUsageAllowed: snapshot.ordinaryUsageAllowed)
        guard showPercent, let shown else { return (nil, shownLevel) }
        return ("\(shown.label) \(Int(shown.window.usedPercent.rounded()))%", shownLevel)
    }

    /// The level of one window; the popover's bars use it too.
    public static func level(usedPercent: Double, ordinaryUsageAllowed: Bool? = true) -> Level {
        if ordinaryUsageAllowed == false || usedPercent >= criticalPercent { return .critical }
        return usedPercent >= warningPercent ? .warning : .normal
    }
}
