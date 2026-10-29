import Foundation
import LimitGuardCore

extension L10n {
    enum Activity {
        static var title: String { tr("activity.title", "Activity") }
        static var menuItem: String { tr("activity.menuItem", "Activity…") }
        static var time: String { tr("activity.col.time", "Time") }
        static var kind: String { tr("activity.col.kind", "Event") }
        static var tab: String { tr("activity.col.tab", "Tab") }
        static var thread: String { tr("activity.col.thread", "Thread") }
        static var text: String { tr("activity.col.text", "Text") }
        static var detail: String { tr("activity.col.detail", "Detail") }
        static var copy: String { tr("activity.copy", "Copy") }
        static var clear: String { tr("activity.clear", "Clear…") }
        static var clearTitle: String { tr("activity.clear.title", "Clear the activity log?") }
        static var clearBody: String { tr("activity.clear.body", "All entries will be removed. This can't be undone.") }
        static var clearConfirm: String { tr("activity.clear.confirm", "Clear") }
        static var empty: String { tr("activity.empty", "No activity yet.") }

        static func kindLabel(_ kind: ActivityKind) -> String {
            switch kind {
            case .limitReached: return tr("activity.kind.limitReached", "Limit reached")
            case .limitIsBack: return tr("activity.kind.limitIsBack", "Limit is back")
            case .continueScheduled: return tr("activity.kind.continueScheduled", "Continue scheduled")
            case .continueSent: return tr("activity.kind.continueSent", "Continue sent")
            case .continueCancelled: return tr("activity.kind.continueCancelled", "Continue cancelled")
            case .continueSkipped: return tr("activity.kind.continueSkipped", "Continue skipped")
            case .unconfirmed: return tr("activity.kind.unconfirmed", "Continue unconfirmed")
            case .loopGuardStop: return tr("activity.kind.loopGuardStop", "Stopped by loop guard")
            case .runawayStop: return tr("activity.kind.runawayStop", "Stopped by runaway brake")
            case .resetUsed: return tr("activity.kind.resetUsed", "Reset credit used")
            case .resetExpiring: return tr("activity.kind.resetExpiring", "Reset credit expiring")
            case .readOnly: return tr("activity.kind.readOnly", "Read-only mode")
            case .permissionDenied: return tr("activity.kind.permissionDenied", "Permission denied")
            case .error: return tr("activity.kind.error", "Error")
            }
        }
    }

    enum Chart {
        static var title: String { tr("chart.title", "Usage Chart") }
        static var menuItem: String { tr("chart.menuItem", "Usage Chart…") }
        static var range: String { tr("chart.range", "Range") }
        static func days(_ count: Int) -> String { tr("chart.range.days", "%ld days", count) }
        static var dailyHeader: String { tr("chart.daily.header", "Daily tokens") }
        static var historyHeader: String { tr("chart.history.header", "Limit history") }
        static var fiveHour: String { tr("chart.fiveHour", "5-hour limit") }
        static var weekly: String { tr("chart.weekly", "Weekly limit") }
        static var loading: String { tr("chart.loading", "Loading…") }
        static var refresh: String { tr("chart.refresh", "Refresh") }
        static var noHistory: String { tr("chart.noHistory", "No limit history yet.") }
        static var timedOut: String { tr("chart.timedOut", "Couldn't load the usage data in time. Try Refresh.") }
        static var axisTokens: String { tr("chart.axis.tokens", "Tokens") }
        static var axisTime: String { tr("chart.axis.time", "Time") }
        static var axisPercent: String { tr("chart.axis.percent", "Percent") }
        static var axisWindow: String { tr("chart.axis.window", "Window") }
        static func peak(_ tokens: String) -> String { tr("chart.peak", "Peak day: %@ tokens", tokens) }
        static func streak(_ days: Int) -> String {
            days == 1 ? tr("chart.streak.one", "Streak: %ld day", days) : tr("chart.streak.other", "Streak: %ld days", days)
        }
        static func forecast(_ date: String) -> String {
            tr("chart.forecast", "At this pace the weekly limit runs out ~%@", date)
        }
    }
}

private func tr(_ key: String, _ english: String) -> String {
    Localization.string(key, english)
}

private func tr(_ key: String, _ english: String, _ arguments: any CVarArg...) -> String {
    Localization.format(key, english, arguments: arguments)
}
