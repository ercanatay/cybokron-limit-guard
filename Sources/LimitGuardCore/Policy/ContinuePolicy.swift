import Foundation

public enum ContinueDecision: Equatable {
    public enum Reason: Equatable {
        case finished, otherError, userActed, tooOld, notGuarded, paused, readOnly, noticeNotAccepted, autoContinueOff
    }

    case notEligible(Reason)
    /// Nothing to do before this moment (limit reset or minimum gap); then decide again.
    case waitUntil(Date)
    /// Time is due but `ordinaryUsageAllowed` is not a fresh `true`: keep polling.
    case waitForGate
    case countdown(seconds: Int)
    case send
    case stopLoopGuard
    case stopRunaway
}

public struct ContinueInputs {
    public var session: SessionState
    public var snapshot: AccountSnapshot
    public var snapshotAge: TimeInterval
    public var health: ProtocolHealth
    public var settings: Settings
    public var loop: LoopRecord
    public var isGuarded: Bool
    public var paused: Bool
    public var now: Date

    public init(
        session: SessionState, snapshot: AccountSnapshot, snapshotAge: TimeInterval, health: ProtocolHealth,
        settings: Settings, loop: LoopRecord, isGuarded: Bool, paused: Bool, now: Date
    ) {
        self.session = session
        self.snapshot = snapshot
        self.snapshotAge = snapshotAge
        self.health = health
        self.settings = settings
        self.loop = loop
        self.isGuarded = isGuarded
        self.paused = paused
        self.now = now
    }
}

/// Pure decision for one session (spec §7.1, §7.2, §7.4, D14). The Engine re-asks after every wake-up.
public enum ContinuePolicy {
    static let maxStopAge: TimeInterval = 24 * 3600
    static let weeklyGrace: TimeInterval = 3600
    static let maxSnapshotAge: TimeInterval = 30
    static let runawayTurns = 3

    public static func decide(_ inputs: ContinueInputs) -> ContinueDecision {
        let settings = inputs.settings
        if Notice.mustShow(settings: settings) { return .notEligible(.noticeNotAccepted) }
        if case .readOnly = inputs.health { return .notEligible(.readOnly) }
        if inputs.paused { return .notEligible(.paused) }
        if !settings.autoContinue { return .notEligible(.autoContinueOff) }
        if !inputs.isGuarded { return .notEligible(.notGuarded) }

        let stopAt: Date
        switch inputs.session.lastStop {
        case .none: return .notEligible(.finished)
        case .otherError: return .notEligible(.otherError)
        case let .usageLimit(at, _): stopAt = at
        }
        if inputs.session.userActivityAfterStop { return .notEligible(.userActed) }

        let weekly = stopIsWeekly(snapshot: inputs.snapshot)
        let weeklyReset = inputs.snapshot.weekly?.resetsAt
        if weekly, let weeklyReset {
            if inputs.now > weeklyReset.addingTimeInterval(weeklyGrace) { return .notEligible(.tooOld) }
        } else if inputs.now.timeIntervalSince(stopAt) > maxStopAge {
            return .notEligible(.tooOld)
        }

        if inputs.loop.consecutive >= settings.maxContinues { return .stopLoopGuard }
        if inputs.loop.shortTurnsInARow >= runawayTurns { return .stopRunaway }

        if let last = inputs.loop.lastSentAt {
            let earliest = last.addingTimeInterval(TimeInterval(settings.minGapSeconds))
            if inputs.now < earliest { return .waitUntil(earliest) }
        }

        guard let resetsAt = weekly ? weeklyReset : inputs.snapshot.fiveHour?.resetsAt else { return .waitForGate }
        if inputs.now < resetsAt { return .waitUntil(resetsAt) }

        guard inputs.snapshot.ordinaryUsageAllowed == true, inputs.snapshotAge <= maxSnapshotAge else {
            return .waitForGate
        }
        return settings.countdownSeconds > 0 ? .countdown(seconds: settings.countdownSeconds) : .send
    }

    /// The weekly window is the one that stopped the session: it is full, or the server names it while
    /// the 5-hour window is not full.
    public static func stopIsWeekly(snapshot: AccountSnapshot) -> Bool {
        if let weekly = snapshot.weekly, weekly.usedPercent >= 100 { return true }
        guard (snapshot.fiveHour?.usedPercent ?? 0) < 100, let reached = snapshot.reachedType?.lowercased() else {
            return false
        }
        return reached.contains("weekly") || reached.contains("secondary")
    }
}
