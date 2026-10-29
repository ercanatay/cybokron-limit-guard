import Foundation

/// What the Engine tells the owner. Every note is logged in Activity; a notification is shown when
/// its `Settings.notify` toggle is on.
public enum EngineNote: Equatable, Sendable {
    case limitReached
    /// `ordinaryUsageAllowed` is still false an hour after the stop's `resetsAt` (spec §7.2).
    case limitStillReached
    case limitIsBack
    case continueCountdown(threadId: String, seconds: Int)
    case continueSent(threadId: String)
    case continueSkipped(threadId: String, reason: String)
    case unconfirmed(threadId: String)
    case loopStopped(threadId: String)
    case runawayStopped(threadId: String)
    case resetUsed(ConsumeOutcome)
    /// A consume whose result is unknown (no answer, an error, or a ledger entry that expired).
    case resetResultUnknown(creditId: String)
    case resetExpiring(creditId: String, at: Date)
    case readOnly(String)

    /// The `Settings.notify` toggle that governs this note.
    public func isEnabled(in toggles: NotificationToggles) -> Bool {
        switch self {
        case .limitReached, .limitStillReached: return toggles.limitReached
        case .limitIsBack: return toggles.limitIsBack
        case .continueCountdown, .continueSent: return toggles.continueSent
        case .continueSkipped, .unconfirmed, .loopStopped, .runawayStopped: return toggles.continueSkipped
        case .resetUsed, .resetResultUnknown: return toggles.resetUsed
        case .resetExpiring: return toggles.resetExpiring
        case .readOnly: return toggles.readOnly
        }
    }

    var activityKind: ActivityKind {
        switch self {
        case .limitReached, .limitStillReached: return .limitReached
        case .limitIsBack: return .limitIsBack
        case .continueCountdown: return .continueScheduled
        case .continueSent: return .continueSent
        case .continueSkipped: return .continueSkipped
        case .unconfirmed: return .unconfirmed
        case .loopStopped: return .loopGuardStop
        case .runawayStopped: return .runawayStop
        case .resetUsed, .resetResultUnknown: return .resetUsed
        case .resetExpiring: return .resetExpiring
        case .readOnly: return .readOnly
        }
    }

    var threadId: String? {
        switch self {
        case let .continueCountdown(id, _), let .continueSent(id), let .continueSkipped(id, _),
             let .unconfirmed(id), let .loopStopped(id), let .runawayStopped(id):
            return id
        default:
            return nil
        }
    }

    var detail: String? {
        switch self {
        case .limitStillReached: return "still reached after resetsAt + 1 h"
        case let .continueCountdown(_, seconds): return "countdown \(seconds) s"
        case let .continueSkipped(_, reason): return reason
        case let .resetUsed(outcome): return "outcome \(outcome)"
        case let .resetResultUnknown(creditId): return "unknown result for credit \(creditId)"
        case let .resetExpiring(creditId, at): return "credit \(creditId) expires \(at.ISO8601Format())"
        case let .readOnly(reason): return reason
        default: return nil
        }
    }
}

/// The next thing the Engine will do on its own, for the popover row.
public struct NextAction: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A guarded session waits for its limit; checked again at this time.
        case continueAt(Date, threadId: String, text: String)
        /// The continue is sent at `until` unless cancelled.
        case countdown(until: Date, threadId: String, text: String)
        /// Automatic reset spending is on and watches the weekly window.
        case autoSpendArmed(threshold: Int)
    }

    public var kind: Kind

    public init(kind: Kind) { self.kind = kind }
}

/// A Terminal tab running Codex, as the popover lists it.
public struct EngineTab: Equatable, Sendable {
    public var tab: TerminalTab
    public var isGuarded: Bool
    /// The thread waiting on a usage-limit stop in this tab, when the mapping is unambiguous.
    public var threadId: String?
    public var isWaiting: Bool

    public init(tab: TerminalTab, isGuarded: Bool, threadId: String?, isWaiting: Bool) {
        self.tab = tab
        self.isGuarded = isGuarded
        self.threadId = threadId
        self.isWaiting = isWaiting
    }
}

/// When the 5-hour and weekly windows run out at the current burn rate (nil: no trustworthy trend).
public struct EngineForecast: Equatable, Sendable {
    public var fiveHour: Date?
    public var weekly: Date?

    public init(fiveHour: Date? = nil, weekly: Date? = nil) {
        self.fiveHour = fiveHour
        self.weekly = weekly
    }
}

/// The system around the Engine: Terminal tabs, notifications, keep-awake.
public protocol EngineEnvironment: Sendable {
    /// Every Terminal tab with a Codex TUI (`CodexProcessLister.listTabs()`); nil when the listing failed.
    func terminalTabs() async -> [TerminalTab]?
    func notify(_ note: EngineNote) async
    func setKeepAwake(_ on: Bool) async
}

/// Where sessions come from (`SessionScanner` in the app).
public protocol SessionSource: Sendable {
    func scan(now: Date) async -> [SessionState]
}

extension SessionScanner: SessionSource {}

/// Delivery plus the loaded threads' working folders, for mapping tabs to threads.
public protocol EngineDelivery: ContinueDelivery {
    /// Throws when the shared app-server daemon cannot be reached.
    func loadedThreadCwds() async throws -> [String: String]
}

extension AppServerDelivery: EngineDelivery {}

/// When to read the limits next (spec §5).
public enum PollSchedule {
    static let normal: TimeInterval = 300
    static let busy: TimeInterval = 60
    static let nearLimitPercent = 90.0
    /// From a stop's `resetsAt`: every 30 s for 5 min, then 1, 2, 5 min until an hour has passed.
    static let afterResetFastPhase: TimeInterval = 300
    static let afterResetPhaseEnd: TimeInterval = 3600

    /// `stopResets`: the `resetsAt` of the stops the Engine waits on. `continuePending`: a continue is
    /// scheduled, counting down or awaiting confirmation.
    public static func nextLimitsRead(after last: Date, snapshot: AccountSnapshot?, stopResets: [Date], continuePending: Bool) -> Date {
        let nearLimit = [snapshot?.fiveHour, snapshot?.weekly].contains { ($0?.usedPercent ?? 0) >= nearLimitPercent }
        var backoff: TimeInterval?
        var upcomingReset: Date?
        for reset in stopResets {
            let elapsed = last.timeIntervalSince(reset)
            if elapsed < 0 {
                upcomingReset = min(upcomingReset ?? reset, reset)
            } else if elapsed < afterResetPhaseEnd {
                backoff = min(backoff ?? .infinity, afterResetInterval(elapsed))
            }
        }
        // The back-off replaces the regular cadence while it runs.
        let interval = backoff ?? (nearLimit || continuePending ? busy : normal)
        let regular = last.addingTimeInterval(interval)
        return min(upcomingReset ?? regular, regular)
    }

    static func afterResetInterval(_ elapsed: TimeInterval) -> TimeInterval {
        switch elapsed {
        case ..<afterResetFastPhase: return 30
        case ..<(afterResetFastPhase + 60): return 60
        case ..<(afterResetFastPhase + 180): return 120
        default: return 300
        }
    }
}
