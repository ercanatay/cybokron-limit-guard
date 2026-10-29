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
    /// One automatic spend per account per this period (D9). Keyed by time, not `resetsAt`, because
    /// the weekly window moves after a reset and must never open a second spend.
    static let markerLifetime: TimeInterval = 7 * 86_400

    /// `hasPendingConsume`: the reset ledger holds an entry without an outcome.
    public static func decideAuto(
        snapshot: AccountSnapshot, health: ProtocolHealth, settings: Settings, state: AppState,
        sessions: [SessionState], paused: Bool, now: Date, hasPendingConsume: Bool
    ) -> AutoSpendDecision {
        if !settings.autoSpendEnabled { return .skip(.disabled) }
        if Notice.mustShow(settings: settings) { return .skip(.noticeNotAccepted) }
        if paused { return .skip(.paused) }
        if case .readOnly = health { return .skip(.readOnly) }
        if hasPendingConsume { return .skip(.pendingConsume) }

        // Without an account id the one-spend marker cannot be checked or written.
        guard let accountId = snapshot.accountId,
              let weekly = snapshot.weekly, let resetsAt = weekly.resetsAt
        else { return .skip(.unknownWindow) }
        if weekly.usedPercent < Double(settings.autoSpendThreshold) { return .skip(.belowThreshold) }
        if alreadySpent(accountId: accountId, marker: state.autoSpend, now: now) {
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

    /// The marker to persist before an automatic spend; nil without an account id (then no spend happens).
    public static func marker(for snapshot: AccountSnapshot, now: Date) -> AutoSpendMarker? {
        snapshot.accountId.map { AutoSpendMarker(accountId: $0, spentAt: now) }
    }

    /// The marker only counts for the account that spent; another (non-nil) account may spend.
    static func alreadySpent(accountId: String, marker: AutoSpendMarker?, now: Date) -> Bool {
        guard let marker, marker.accountId == accountId else { return false }
        return now.timeIntervalSince(marker.spentAt) < markerLifetime
    }
}
