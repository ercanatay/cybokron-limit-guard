import Foundation
import Testing
@testable import LimitGuardCore

@Suite struct ContinuePolicyTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func settings(accepted: Bool = true) -> Settings {
        var s = Settings()
        if accepted { s.noticeAcceptedVersion = Notice.currentVersion }
        return s
    }

    /// Eligible by default: usage-limit stop 1 h ago, 5-hour window reset 10 min ago, gate open, fresh.
    static func inputs(
        stop: StopKind? = nil, userActed: Bool = false, fiveHourResets: Date?? = nil, weekly: RateLimitWindow? = nil,
        reachedType: String? = nil, fiveHourUsed: Double = 100, allowed: Bool? = true, age: TimeInterval = 5, health: ProtocolHealth = .full,
        settings: Settings = settings(), loop: LoopRecord = LoopRecord(), guarded: Bool = true, paused: Bool = false
    ) -> ContinueInputs {
        let now = Self.now
        let resets = fiveHourResets ?? now.addingTimeInterval(-600)
        let snapshot = AccountSnapshot(
            ordinaryUsageAllowed: allowed,
            fiveHour: RateLimitWindow(usedPercent: fiveHourUsed, windowMinutes: 300, resetsAt: resets),
            weekly: weekly ?? RateLimitWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
            planType: nil, reachedType: reachedType, accountId: nil, credits: [], availableCreditCount: 0, readAt: now)
        let session = SessionState(
            threadId: "t", cwd: "/tmp", originator: "codex-tui",
            lastStop: stop ?? .usageLimit(at: now.addingTimeInterval(-3600), turnId: "u"),
            userActivityAfterStop: userActed, lastActivityAt: now, lastTurnDurations: [], languageSample: "",
            seenClientMessageIds: [])
        return ContinueInputs(
            session: session, snapshot: snapshot, snapshotAge: age, health: health, settings: settings, loop: loop,
            isGuarded: guarded, paused: paused, now: now)
    }

    func decide(_ i: ContinueInputs) -> ContinueDecision { ContinuePolicy.decide(i) }

    @Test func finishedSessionNotEligible() { #expect(decide(Self.inputs(stop: StopKind.none)) == .notEligible(.finished)) }
    @Test func otherErrorNotEligible() { #expect(decide(Self.inputs(stop: .otherError("server_overloaded"))) == .notEligible(.otherError)) }
    @Test func userActedNotEligible() { #expect(decide(Self.inputs(userActed: true)) == .notEligible(.userActed)) }
    @Test func noticeNotAcceptedBlocks() { #expect(decide(Self.inputs(settings: Self.settings(accepted: false))) == .notEligible(.noticeNotAccepted)) }
    @Test func pausedBlocks() { #expect(decide(Self.inputs(paused: true)) == .notEligible(.paused)) }
    @Test func readOnlyBlocks() { #expect(decide(Self.inputs(health: .readOnly(reason: "x"))) == .notEligible(.readOnly)) }
    @Test func unguardedBlocks() { #expect(decide(Self.inputs(guarded: false)) == .notEligible(.notGuarded)) }
    @Test func autoContinueOffBlocks() {
        var s = Self.settings()
        s.autoContinue = false
        #expect(decide(Self.inputs(settings: s)) == .notEligible(.autoContinueOff))
    }

    @Test func stopOlderThan24hIsTooOld() {
        let old = StopKind.usageLimit(at: Self.now.addingTimeInterval(-25 * 3600), turnId: "u")
        #expect(decide(Self.inputs(stop: old)) == .notEligible(.tooOld))
    }

    @Test func weeklyStopUsesResetsAtPlusOneHour() {
        let old = StopKind.usageLimit(at: Self.now.addingTimeInterval(-3 * 86400), turnId: "u")
        func weekly(_ ago: TimeInterval) -> RateLimitWindow {
            RateLimitWindow(usedPercent: 100, windowMinutes: 10080, resetsAt: Self.now.addingTimeInterval(-ago))
        }
        #expect(decide(Self.inputs(stop: old, weekly: weekly(30 * 60))) == .countdown(seconds: 10))
        #expect(decide(Self.inputs(stop: old, weekly: weekly(61 * 60))) == .notEligible(.tooOld))
    }

    @Test func weeklyStopWithoutResetsAtUses24hRule() {
        let old = StopKind.usageLimit(at: Self.now.addingTimeInterval(-3 * 86400), turnId: "u")
        let weekly = RateLimitWindow(usedPercent: 100, windowMinutes: 10080, resetsAt: nil)
        #expect(decide(Self.inputs(stop: old, weekly: weekly)) == .notEligible(.tooOld))
    }

    @Test func stopIsWeeklyDetection() {
        let full = RateLimitWindow(usedPercent: 100, windowMinutes: 10080, resetsAt: nil)
        #expect(ContinuePolicy.stopIsWeekly(snapshot: Self.inputs(weekly: full).snapshot))
        #expect(!ContinuePolicy.stopIsWeekly(snapshot: Self.inputs().snapshot))
        #expect(ContinuePolicy.stopIsWeekly(snapshot: Self.inputs(reachedType: "weekly", fiveHourUsed: 60).snapshot))
        #expect(!ContinuePolicy.stopIsWeekly(snapshot: Self.inputs(reachedType: "five_hour", fiveHourUsed: 60).snapshot))
        #expect(!ContinuePolicy.stopIsWeekly(snapshot: Self.inputs(reachedType: "weekly").snapshot))
    }

    @Test func beforeResetsAtWaits() {
        let resets = Self.now.addingTimeInterval(1800)
        #expect(decide(Self.inputs(fiveHourResets: .some(resets))) == .waitUntil(resets))
    }

    @Test func weeklyStopWaitsForWeeklyResetsAt() {
        let resets = Self.now.addingTimeInterval(7200)
        let weekly = RateLimitWindow(usedPercent: 100, windowMinutes: 10080, resetsAt: resets)
        #expect(decide(Self.inputs(weekly: weekly)) == .waitUntil(resets))
    }

    @Test func missingResetsAtWaitsForGate() {
        #expect(decide(Self.inputs(fiveHourResets: .some(nil))) == .waitForGate)
    }

    @Test func gateFalseWaitsForGate() { #expect(decide(Self.inputs(allowed: false)) == .waitForGate) }
    @Test func gateNilWaitsForGate() { #expect(decide(Self.inputs(allowed: nil)) == .waitForGate) }
    @Test func staleSnapshotWaitsForGate() { #expect(decide(Self.inputs(age: 31)) == .waitForGate) }
    @Test func snapshotExactly30sIsFresh() { #expect(decide(Self.inputs(age: 30)) == .countdown(seconds: 10)) }

    @Test func gateTrueStartsCountdown() {
        #expect(decide(Self.inputs()) == .countdown(seconds: 10))
        var s = Self.settings()
        s.countdownSeconds = 0
        #expect(decide(Self.inputs(settings: s)) == .send)
    }

    @Test func loopGuardAfterThree() {
        #expect(decide(Self.inputs(loop: LoopRecord(consecutive: 3))) == .stopLoopGuard)
        #expect(decide(Self.inputs(loop: LoopRecord(consecutive: 2))) == .countdown(seconds: 10))
    }

    @Test func minGapTwoMinutes() {
        let last = Self.now.addingTimeInterval(-90)
        #expect(decide(Self.inputs(loop: LoopRecord(consecutive: 1, lastSentAt: last))) == .waitUntil(last.addingTimeInterval(120)))
    }

    @Test func runawayBrake() {
        #expect(decide(Self.inputs(loop: LoopRecord(consecutive: 1, shortTurnsInARow: 3))) == .stopRunaway)
    }
}
