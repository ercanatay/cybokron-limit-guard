import Foundation
import LimitGuardCore

/// The menu-bar popover's texts (spec §4.2, §4.4). Credit titles come from the backend and are
/// never looked up here.
extension L10n {
    enum Popover {
        enum Status {
            static var codexMissing: String { tr("popover.status.codexMissing", "Codex not found. Set its path in Settings.") }
            static var notSignedIn: String {
                tr("popover.status.notSignedIn", "Codex isn't signed in — run `codex login` in Terminal")
            }
            static var readFailed: String {
                tr("popover.status.readFailed", "Codex app-server didn't answer. Trying again…")
            }
            static var noCodexTab: String { tr("popover.status.noCodexTab", "No Codex tab is open in Terminal.") }
            static var noneGuarded: String { tr("popover.status.noneGuarded", "No session is guarded. Tick one below.") }
            static func watching(_ count: Int) -> String {
                count == 1
                    ? tr("popover.status.watching.one", "Watching %ld Codex session", count)
                    : tr("popover.status.watching.other", "Watching %ld Codex sessions", count)
            }
            static var readOnly: String { tr("popover.status.readOnly", "Read-only: Codex protocol changed") }
            static var notificationsOff: String {
                tr("popover.status.notificationsOff", "Notifications are off. The popover still shows everything.")
            }
            static var openNotificationSettings: String { tr("popover.status.openNotificationSettings", "Allow…") }
        }

        enum Limit {
            static var fiveHour: String { tr("popover.limit.fiveHour", "5-hour limit") }
            static var weekly: String { tr("popover.limit.weekly", "Weekly limit") }
            static var notReported: String { tr("popover.limit.notReported", "Not reported") }
            /// "100 % used"; `percent` is already formatted.
            static func used(_ percent: String) -> String { tr("popover.limit.used", "%@ used", percent) }
            /// "resets in 3 h 42 m (18:15)".
            static func resetsIn(_ duration: String, _ clock: String) -> String {
                tr("popover.limit.resetsIn", "resets in %1$@ (%2$@)", duration, clock)
            }
            static func fiveHourForecast(_ date: String) -> String {
                tr("popover.limit.forecastFiveHour", "At this pace the 5-hour limit runs out ~%@", date)
            }
        }

        enum Next {
            static var title: String { tr("popover.next.title", "Next action") }
            /// "At 18:15 send “devam et” — ~/project (ttys003)".
            static func continueAt(_ time: String, _ text: String, _ target: String) -> String {
                tr("popover.next.continueAt", "At %1$@ send “%2$@” — %3$@", time, text, target)
            }
            static func countdown(_ text: String, _ seconds: Int, _ target: String) -> String {
                tr("popover.next.countdown", "Sending “%1$@” in %2$ld s — %3$@", text, seconds, target)
            }
            /// `threshold` is already formatted ("97 %").
            static func autoSpend(_ threshold: String) -> String {
                tr("popover.next.autoSpend", "Will use 1 reset when weekly reaches %@", threshold)
            }
            static var unknownTarget: String { tr("popover.next.unknownTarget", "a Codex session") }
        }

        enum Resets {
            static var title: String { tr("popover.resets.title", "Usage limit resets") }
            static func available(_ count: Int) -> String {
                count == 1
                    ? tr("popover.resets.available.one", "%ld available", count)
                    : tr("popover.resets.available.other", "%ld available", count)
            }
            static var none: String { tr("popover.resets.none", "No resets right now.") }
            /// Shown when the backend sends a credit without a title.
            static var untitled: String { tr("popover.resets.untitled", "Full reset") }
            /// "Expires 29 Oct 22:29 GMT+3".
            static func expires(_ date: String, _ zone: String) -> String {
                tr("popover.resets.expires", "Expires %1$@ %2$@", date, zone)
            }
            static var neverExpires: String { tr("popover.resets.neverExpires", "Doesn't expire") }
            static var expiresToday: String { tr("popover.resets.expiresToday", "expires today") }
            static var expiresTomorrow: String { tr("popover.resets.expiresTomorrow", "expires tomorrow") }
            static var use: String { tr("popover.resets.use", "Use Reset") }
            static var redeeming: String { tr("popover.resets.redeeming", "Being used…") }
            static var redeemed: String { tr("popover.resets.redeemed", "Used") }
            static var confirmTitle: String { tr("popover.resets.confirmTitle", "Use this reset now?") }
            static var confirmMessage: String { tr("popover.resets.confirmMessage", "This can't be undone.") }
            static var inFlight: String { tr("popover.resets.inFlight", "Using the reset…") }
            static var noLongerAvailable: String {
                tr("popover.resets.noLongerAvailable", "This reset is no longer available")
            }
            static var readOnlyHint: String {
                tr("popover.resets.readOnlyHint", "Resets can't be used in read-only mode.")
            }

            static func result(_ result: SpendResult) -> String {
                switch result {
                case .outcome(.reset): return tr("popover.resets.result.reset", "Usage reset")
                case .outcome(.nothingToReset): return tr("popover.resets.result.nothing", "Nothing to reset right now")
                case .outcome(.noCredit): return tr("popover.resets.result.noCredit", "No resets available")
                case .outcome(.alreadyRedeemed): return tr("popover.resets.result.redeemed", "Already used")
                case .unknown:
                    return tr("popover.resets.result.unknown", "Result unknown. Check your account before trying again.")
                case .busy: return tr("popover.resets.result.busy", "Not sent: another reset is still pending.")
                }
            }
        }

        enum Sessions {
            static var title: String { tr("popover.sessions.title", "Codex sessions") }
            static var none: String { tr("popover.sessions.none", "Open Codex in a Terminal tab to guard it.") }
            static var guardHelp: String {
                tr("popover.sessions.guardHelp", "Guarded tabs are continued automatically after the limit resets.")
            }
            static func thread(_ shortId: String) -> String { tr("popover.sessions.thread", "Thread %@", shortId) }
            static var waitingGuarded: String {
                tr("popover.sessions.waitingGuarded", "Waiting on the limit. Continues automatically.")
            }
            static var waitingNotGuarded: String { tr("popover.sessions.waitingNotGuarded", "waiting (not guarded)") }
            static var ambiguous: String {
                tr("popover.sessions.ambiguous", "Can’t tell which conversation — continue by hand")
            }
            static var continueNow: String { tr("popover.sessions.continueNow", "Continue now") }
            static var continueNeedsLimit: String {
                tr("popover.sessions.continueNeedsLimit", "Available once the limit is back.")
            }
        }

        enum Footer {
            static var pause: String { tr("popover.footer.pause", "Pause") }
            static var resume: String { tr("popover.footer.resume", "Resume") }
            static var pauseHelp: String { tr("popover.footer.pauseHelp", "Pause automatic continuing and spending") }
            static func plan(_ name: String) -> String { tr("popover.footer.plan", "Plan: %@", name) }
        }
    }
}

private func tr(_ key: String, _ english: String) -> String {
    Localization.string(key, english)
}

private func tr(_ key: String, _ english: String, _ arguments: any CVarArg...) -> String {
    Localization.format(key, english, arguments: arguments)
}
