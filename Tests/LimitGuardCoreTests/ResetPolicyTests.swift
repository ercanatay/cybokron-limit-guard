import Foundation
import Testing
@testable import LimitGuardCore

@Suite("ResetPolicy")
struct ResetPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func credit(_ id: String, expires: TimeInterval?, status: ResetCreditStatus = .available) -> ResetCredit {
        ResetCredit(id: id, status: status, grantedAt: Date(timeIntervalSince1970: 1_780_000_000),
                    expiresAt: expires.map { Date(timeIntervalSince1970: $0) }, title: nil, detail: nil)
    }

    private func snapshot(
        weeklyUsed: Double = 98, resetsIn: TimeInterval? = 3 * 86_400, fiveHourUsed: Double = 100,
        accountId: String? = "a", credits: [ResetCredit]? = nil
    ) -> AccountSnapshot {
        let list = credits ?? [credit("c1", expires: 1_795_000_000)]
        return AccountSnapshot(
            ordinaryUsageAllowed: false,
            fiveHour: RateLimitWindow(usedPercent: fiveHourUsed, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600)),
            weekly: RateLimitWindow(usedPercent: weeklyUsed, windowMinutes: 10_080, resetsAt: resetsIn.map { now.addingTimeInterval($0) }),
            planType: "pro", reachedType: nil, accountId: accountId,
            credits: list, availableCreditCount: list.filter { $0.status == .available }.count, readAt: now)
    }

    private func enabledSettings() -> Settings {
        var settings = Settings()
        settings.autoSpendEnabled = true
        settings.noticeAcceptedVersion = Notice.currentVersion
        return settings
    }

    private func session(lastActivityAgo: TimeInterval, stop: StopKind = .none, userActed: Bool = false) -> SessionState {
        SessionState(threadId: "t1", cwd: "/tmp", originator: "codex_cli_rs", lastStop: stop,
                     userActivityAfterStop: userActed, lastActivityAt: now.addingTimeInterval(-lastActivityAgo),
                     lastTurnDurations: [], languageSample: "", seenClientMessageIds: [])
    }

    private func decide(
        _ snapshot: AccountSnapshot, settings: Settings? = nil, state: AppState = AppState(),
        sessions: [SessionState]? = nil, health: ProtocolHealth = .full, paused: Bool = false,
        hasPendingConsume: Bool = false
    ) -> AutoSpendDecision {
        ResetPolicy.decideAuto(
            snapshot: snapshot, health: health, settings: settings ?? enabledSettings(), state: state,
            sessions: sessions ?? [session(lastActivityAgo: 300)], paused: paused, now: now,
            hasPendingConsume: hasPendingConsume)
    }

    @Test func disabledByDefault() {
        #expect(decide(snapshot(), settings: Settings()) == .skip(.disabled))
    }

    @Test func belowThresholdSkips() {
        #expect(decide(snapshot(weeklyUsed: 96.9)) == .skip(.belowThreshold))
    }

    @Test func atThresholdSpendsEarliestExpiring() {
        let credits = [credit("late", expires: 1_795_000_000), credit("early", expires: 1_793_302_182)]
        #expect(decide(snapshot(weeklyUsed: 97, credits: credits)) == .spend(creditId: "early"))
    }

    @Test func fiveHourStateIrrelevant() {
        #expect(decide(snapshot(fiveHourUsed: 10)) == .spend(creditId: "c1"))
    }

    @Test func alreadySpentThisWindowSkips() {
        let snap = snapshot()
        var state = AppState()
        state.autoSpendWindowKey = snap.weekly?.resetsAt
        state.autoSpendAccountId = "a"
        #expect(decide(snap, state: state) == .skip(.alreadySpentThisWindow))
    }

    @Test func accountChangeIgnoresOldWindowMarker() {
        let snap = snapshot(accountId: "b")
        var state = AppState()
        state.autoSpendWindowKey = snap.weekly?.resetsAt
        state.autoSpendAccountId = "a"
        #expect(decide(snap, state: state) == .spend(creditId: "c1"))
    }

    @Test func codexIdleSkips() {
        #expect(decide(snapshot(), sessions: [session(lastActivityAgo: 31 * 60)]) == .skip(.codexIdle))
        #expect(decide(snapshot(), sessions: []) == .skip(.codexIdle))
    }

    @Test func activityExactlyThirtyMinutesAgoCountsAsInUse() {
        #expect(decide(snapshot(), sessions: [session(lastActivityAgo: 30 * 60)]) == .spend(creditId: "c1"))
    }

    @Test func waitingUsageLimitStopCountsAsInUse() {
        let stopped = session(lastActivityAgo: 5 * 3600, stop: .usageLimit(at: now.addingTimeInterval(-5 * 3600), turnId: "turn-1"))
        #expect(decide(snapshot(), sessions: [stopped]) == .spend(creditId: "c1"))
    }

    @Test func stopTheUserActedOnDoesNotCountAsInUse() {
        let stopped = session(lastActivityAgo: 5 * 3600,
                              stop: .usageLimit(at: now.addingTimeInterval(-5 * 3600), turnId: "turn-1"), userActed: true)
        #expect(decide(snapshot(), sessions: [stopped]) == .skip(.codexIdle))
    }

    @Test func weeklyStopOlderThanADayStillCountsUntilWindowReset() {
        let stopAt = now.addingTimeInterval(-3 * 86_400)
        let stopped = session(lastActivityAgo: 3 * 86_400, stop: .usageLimit(at: stopAt, turnId: "turn-w"))
        let snap = snapshot()
        var state = AppState()
        state.stops["t1"] = StopInfo(turnId: "turn-w", isWeekly: true, resetsAt: snap.weekly?.resetsAt)
        #expect(decide(snap, state: state, sessions: [stopped]) == .spend(creditId: "c1"))
        // Without the recorded weekly classification the 24 h rule applies.
        #expect(decide(snapshot(weeklyUsed: 98), sessions: [stopped]) == .skip(.codexIdle))
    }

    @Test func windowResetsSoonSkips() {
        #expect(decide(snapshot(resetsIn: 11 * 3600 + 59 * 60)) == .skip(.windowResetsSoon))
        #expect(decide(snapshot(resetsIn: 12 * 3600)) == .spend(creditId: "c1"))
    }

    @Test func unknownWindowSkips() {
        #expect(decide(snapshot(resetsIn: nil)) == .skip(.unknownWindow))
        var snap = snapshot()
        snap.weekly = nil
        #expect(decide(snap) == .skip(.unknownWindow))
    }

    @Test func nullExpiryChosenLast() {
        let credits = [credit("never", expires: nil), credit("dated", expires: 1_799_000_000)]
        #expect(decide(snapshot(credits: credits)) == .spend(creditId: "dated"))
        #expect(decide(snapshot(credits: [credit("never", expires: nil)])) == .spend(creditId: "never"))
    }

    @Test func noAvailableCreditSkips() {
        #expect(decide(snapshot(credits: [credit("r", expires: 1_795_000_000, status: .redeeming)])) == .skip(.noCredit))
        #expect(decide(snapshot(credits: [])) == .skip(.noCredit))
    }

    @Test func gatesSkip() {
        #expect(decide(snapshot(), paused: true) == .skip(.paused))
        #expect(decide(snapshot(), health: .readOnly(reason: "x")) == .skip(.readOnly))
        var settings = enabledSettings()
        settings.noticeAcceptedVersion = nil
        #expect(decide(snapshot(), settings: settings) == .skip(.noticeNotAccepted))
        #expect(decide(snapshot(), hasPendingConsume: true) == .skip(.pendingConsume))
    }

    @Test func expiringSoonUnder24h() {
        let credits = [
            credit("soon", expires: now.addingTimeInterval(23 * 3600).timeIntervalSince1970),
            credit("later", expires: now.addingTimeInterval(25 * 3600).timeIntervalSince1970),
            credit("never", expires: nil),
            credit("gone", expires: now.addingTimeInterval(-60).timeIntervalSince1970),
            credit("used", expires: now.addingTimeInterval(3600).timeIntervalSince1970, status: .redeemed),
        ]
        #expect(ResetPolicy.expiringSoon(credits: credits, now: now).map(\.id) == ["soon"])
    }
}
