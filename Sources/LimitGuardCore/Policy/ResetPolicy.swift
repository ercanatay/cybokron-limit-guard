import Foundation

public enum AutoSpendDecision: Equatable {
    public enum SkipReason: Equatable {
        case disabled, paused, readOnly, noticeNotAccepted, belowThreshold, noCredit
        case alreadySpentThisWindow, pendingConsume, codexIdle, windowResetsSoon, unknownWindow
    }

    case spend(creditId: String)
    case skip(SkipReason)
}

/// Pure decision for the automatic reset-credit spend (spec §8.1, D9, D15). Run on a fresh read only.
public enum ResetPolicy {
    static let inUseWindow: TimeInterval = 30 * 60
    static let resetsSoonWindow: TimeInterval = 12 * 3600
    static let expiryReminderWindow: TimeInterval = 24 * 3600

    /// `hasPendingConsume`: the reset ledger holds an entry without an outcome.
    public static func decideAuto(
        snapshot: AccountSnapshot, health: ProtocolHealth, settings: Settings, state: AppState,
        sessions: [SessionState], paused: Bool, now: Date, hasPendingConsume: Bool = false
    ) -> AutoSpendDecision {
        if !settings.autoSpendEnabled { return .skip(.disabled) }
        if Notice.mustShow(settings: settings) { return .skip(.noticeNotAccepted) }
        if paused { return .skip(.paused) }
        if case .readOnly = health { return .skip(.readOnly) }
        if hasPendingConsume { return .skip(.pendingConsume) }

        guard let weekly = snapshot.weekly, let resetsAt = weekly.resetsAt else { return .skip(.unknownWindow) }
        if weekly.usedPercent < Double(settings.autoSpendThreshold) { return .skip(.belowThreshold) }
        if alreadySpent(in: resetsAt, accountId: snapshot.accountId, state: state) {
            return .skip(.alreadySpentThisWindow)
        }
        if resetsAt.timeIntervalSince(now) < resetsSoonWindow { return .skip(.windowResetsSoon) }

        // `credits` is only sorted when it came from `decode`; sort again so the choice never depends on that.
        let available = AccountSnapshot.sortedByExpiry(snapshot.availableCredits)
        // Spec §8.1 needs both: the server's count and a listed credit with `status == available`.
        guard snapshot.availableCreditCount >= 1, let credit = available.first else {
            return .skip(.noCredit)
        }

        let inUse = sessions.contains { session in
            session.lastActivityAt >= now.addingTimeInterval(-inUseWindow)
                || ContinuePolicy.isWaitingOnUsageLimit(
                    session: session, snapshot: snapshot, stopInfo: state.stops[session.threadId], now: now)
        }
        if !inUse { return .skip(.codexIdle) }

        return .spend(creditId: credit.id)
    }

    /// Available credits that expire within the next 24 h, earliest first.
    public static func expiringSoon(credits: [ResetCredit], now: Date) -> [ResetCredit] {
        AccountSnapshot.sortedByExpiry(credits.filter { credit in
            guard credit.status == .available, let expiresAt = credit.expiresAt else { return false }
            let left = expiresAt.timeIntervalSince(now)
            return left > 0 && left < expiryReminderWindow
        })
    }

    /// The window marker only counts for the account that spent in it; a nil account id on both
    /// sides counts as the same account (the safe reading). Compared in whole seconds because
    /// `AppState` stores dates as ISO 8601 without fractions.
    static func alreadySpent(in resetsAt: Date, accountId: String?, state: AppState) -> Bool {
        guard let key = state.autoSpendWindowKey, state.autoSpendAccountId == accountId else { return false }
        return key.timeIntervalSince1970.rounded(.down) == resetsAt.timeIntervalSince1970.rounded(.down)
    }
}
