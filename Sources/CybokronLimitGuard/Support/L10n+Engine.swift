import Foundation
import LimitGuardCore

/// Notification texts and the engine status words.
extension L10n {
    enum Notify {
        static var permissionTitle: String { tr("notify.permission.title", "Allow notifications?") }
        static var permissionMessage: String {
            tr(
                "notify.permission.message",
                "Limit Guard can tell you when your Codex limit is reached or back, and when it continues a session for you. macOS asks for permission next."
            )
        }
        static var permissionContinue: String { tr("notify.permission.continue", "Continue") }
        static var cancelAction: String { tr("notify.action.cancel", "Cancel") }

        static var limitReached: (title: String, body: String) {
            (
                tr("notify.limitReached.title", "Codex limit reached"),
                tr("notify.limitReached.body", "Guarded sessions continue after the limit resets.")
            )
        }
        static var limitStillReached: (title: String, body: String) {
            (
                tr("notify.limitStillReached.title", "Codex limit still reached"),
                tr("notify.limitStillReached.body", "Codex still reports the limit as reached an hour after the expected reset.")
            )
        }
        static var limitIsBack: (title: String, body: String) {
            (
                tr("notify.limitIsBack.title", "Codex limit is back"),
                tr("notify.limitIsBack.body", "You can use Codex again.")
            )
        }
        static func countdown(_ seconds: Int) -> (title: String, body: String) {
            (
                tr("notify.countdown.title", "Continuing in %ld s", seconds),
                tr("notify.countdown.body", "Limit Guard is about to continue a waiting Codex session. Cancel to stop it.")
            )
        }
        static var continueSent: (title: String, body: String) {
            (
                tr("notify.continueSent.title", "Continue sent"),
                tr("notify.continueSent.body", "Limit Guard continued a waiting Codex session.")
            )
        }
        static func continueSkipped(_ reason: String) -> (title: String, body: String) {
            (tr("notify.continueSkipped.title", "Continue skipped"), reason)
        }
        static var unconfirmed: (title: String, body: String) {
            (
                tr("notify.unconfirmed.title", "Continue not confirmed"),
                tr("notify.unconfirmed.body", "Codex did not confirm the message. Nothing was sent again; check the session.")
            )
        }
        static var loopStopped: (title: String, body: String) {
            (
                tr("notify.loopStopped.title", "Stopped continuing"),
                tr("notify.loopStopped.body", "A session reached the maximum number of automatic continues.")
            )
        }
        static var runawayStopped: (title: String, body: String) {
            (
                tr("notify.runawayStopped.title", "Stopped continuing"),
                tr("notify.runawayStopped.body", "Continued turns keep ending within a minute, so Limit Guard stopped.")
            )
        }
        static func resetUsed(_ outcome: ConsumeOutcome) -> (title: String, body: String) {
            switch outcome {
            case .reset:
                return (
                    tr("notify.resetUsed.reset.title", "Reset credit used"),
                    tr("notify.resetUsed.reset.body", "Your Codex limits were reset.")
                )
            case .nothingToReset:
                return (
                    tr("notify.resetUsed.nothing.title", "Nothing to reset"),
                    tr("notify.resetUsed.nothing.body", "Your limits were not in use, so the credit was kept.")
                )
            case .noCredit:
                return (
                    tr("notify.resetUsed.noCredit.title", "No reset credit"),
                    tr("notify.resetUsed.noCredit.body", "There was no reset credit to use.")
                )
            case .alreadyRedeemed:
                return (
                    tr("notify.resetUsed.redeemed.title", "Reset credit already used"),
                    tr("notify.resetUsed.redeemed.body", "That reset credit had already been redeemed.")
                )
            }
        }
        static var resetUnknown: (title: String, body: String) {
            (
                tr("notify.resetUnknown.title", "Reset result unknown"),
                tr("notify.resetUnknown.body", "Limit Guard could not confirm whether the reset credit was used. Check your account before trying again.")
            )
        }
        static func resetExpiring(_ date: String) -> (title: String, body: String) {
            (
                tr("notify.resetExpiring.title", "Reset credit expires soon"),
                tr("notify.resetExpiring.body", "A reset credit expires %@.", date)
            )
        }
        static func readOnly(_ reason: String) -> (title: String, body: String) {
            (tr("notify.readOnly.title", "Read-only mode"), reason)
        }
    }

    /// Status texts the popover shares with other places.
    enum EngineStatus {
        static var starting: String { tr("engineStatus.starting", "Starting…") }
        static var reading: String { tr("engineStatus.reading", "Reading limits…") }
        static var paused: String { tr("engineStatus.paused", "Paused") }
    }
}

private func tr(_ key: String, _ english: String) -> String {
    Localization.string(key, english)
}

private func tr(_ key: String, _ english: String, _ arguments: any CVarArg...) -> String {
    Localization.format(key, english, arguments: arguments)
}
