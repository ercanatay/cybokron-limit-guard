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

/// How a usage-limit stop was classified when first seen. Kept because the live windows move on once
/// the limit resets, which would change the stop's age rule and wait target.
public struct StopInfo: Codable, Equatable, Sendable {
    public var turnId: String
    public var isWeekly: Bool
    public var resetsAt: Date?

    public init(turnId: String, isWeekly: Bool, resetsAt: Date?) {
        self.turnId = turnId
        self.isWeekly = isWeekly
        self.resetsAt = resetsAt
    }
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
    /// Recorded classification of the current stop; ignored when nil or for another turn.
    public var stopInfo: StopInfo?

    public init(
        session: SessionState, snapshot: AccountSnapshot, snapshotAge: TimeInterval, health: ProtocolHealth,
        settings: Settings, loop: LoopRecord, isGuarded: Bool, paused: Bool, now: Date,
        stopInfo: StopInfo? = nil
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
        self.stopInfo = stopInfo
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
        let turnId: String
        switch inputs.session.lastStop {
        case .none: return .notEligible(.finished)
        case .otherError: return .notEligible(.otherError)
        case let .usageLimit(at, id): stopAt = at; turnId = id
        }
        if inputs.session.userActivityAfterStop { return .notEligible(.userActed) }

        var info = classifyStop(turnId: turnId, snapshot: inputs.snapshot)
        if let recorded = inputs.stopInfo, recorded.turnId == turnId { info = recorded }

        if info.isWeekly, let resetsAt = info.resetsAt {
            if inputs.now > resetsAt.addingTimeInterval(weeklyGrace) { return .notEligible(.tooOld) }
        } else if inputs.now.timeIntervalSince(stopAt) > maxStopAge {
            return .notEligible(.tooOld)
        }

        if inputs.loop.consecutive >= settings.maxContinues { return .stopLoopGuard }
        if inputs.loop.shortTurnsInARow >= runawayTurns { return .stopRunaway }

        // resetsAt only schedules the first check; an open, fresh gate overrides it (spec 7.2).
        let gateOpen = inputs.snapshot.ordinaryUsageAllowed == true && inputs.snapshotAge <= maxSnapshotAge
        var waits: [Date] = []
        if let last = inputs.loop.lastSentAt {
            waits.append(last.addingTimeInterval(TimeInterval(settings.minGapSeconds)))
        }
        if !gateOpen, let resetsAt = info.resetsAt { waits.append(resetsAt) }
        if let until = waits.max(), until > inputs.now { return .waitUntil(until) }
        if !gateOpen { return .waitForGate }
        return settings.countdownSeconds > 0 ? .countdown(seconds: settings.countdownSeconds) : .send
    }

    /// Records which window stopped the session and when it resets; call when a stop is first seen.
    public static func classifyStop(turnId: String, snapshot: AccountSnapshot) -> StopInfo {
        let weekly = stopIsWeekly(snapshot: snapshot)
        return StopInfo(turnId: turnId, isWeekly: weekly, resetsAt: weekly ? snapshot.weekly?.resetsAt : snapshot.fiveHour?.resetsAt)
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
