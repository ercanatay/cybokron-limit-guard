import Foundation

/// How a thread's last turn ended.
public enum StopKind: Equatable, Sendable {
    /// Finished normally, or no turn has ended yet.
    case none
    /// `codex_error_info == "usage_limit_exceeded"`: the only stop auto-continue acts on.
    case usageLimit(at: Date, turnId: String)
    /// Any other error (`server_overloaded`, …); never continued.
    case otherError(String)
}

/// What the app knows about one Codex thread, built from its index row and rollout tail.
public struct SessionState: Equatable, Sendable {
    static let usageLimitErrorInfo = "usage_limit_exceeded"
    /// Durations kept for the runaway brake (spec §7.4 needs the last 3).
    static let keptTurnDurations = 5

    public var threadId: String
    public var cwd: String
    public var originator: String?
    public var lastStop: StopKind
    /// A user message, a new turn or an aborted turn appeared after the last turn ended.
    public var userActivityAfterStop: Bool
    public var lastActivityAt: Date
    /// Seconds from `task_started` to `task_complete` of the last turns, oldest first.
    public var lastTurnDurations: [TimeInterval]
    public var languageSample: String
    public var seenClientMessageIds: Set<String>

    public init(
        threadId: String, cwd: String, originator: String?, lastStop: StopKind, userActivityAfterStop: Bool,
        lastActivityAt: Date, lastTurnDurations: [TimeInterval], languageSample: String,
        seenClientMessageIds: Set<String>
    ) {
        self.threadId = threadId
        self.cwd = cwd
        self.originator = originator
        self.lastStop = lastStop
        self.userActivityAfterStop = userActivityAfterStop
        self.lastActivityAt = lastActivityAt
        self.lastTurnDurations = lastTurnDurations
        self.languageSample = languageSample
        self.seenClientMessageIds = seenClientMessageIds
    }

    /// `events` in file order (see `RolloutReader`). Activity after the stop is judged by order, not
    /// time: `task_started` is written before the user message that triggers it.
    public static func build(thread: ThreadRow, events: [RolloutEvent]) -> SessionState {
        var metaCwd: String?
        var metaOriginator: String?
        var lastStop = StopKind.none
        var activityAfterStop = false
        var lastActivity = thread.updatedAt
        var startedAt: [String: Date] = [:]
        var durations: [TimeInterval] = []
        var userTexts: [String] = []
        var clientIds: Set<String> = []

        for event in events {
            if let date = event.date, date > lastActivity { lastActivity = date }
            switch event {
            case let .sessionMeta(_, cwd, originator, _):
                metaCwd = cwd
                metaOriginator = originator
            case let .taskStarted(turnId, at):
                startedAt[turnId] = at
                activityAfterStop = true
            case let .taskComplete(turnId, at, errorInfo):
                if let started = startedAt.removeValue(forKey: turnId) {
                    durations.append(at.timeIntervalSince(started))
                }
                switch errorInfo {
                case nil: lastStop = .none
                case usageLimitErrorInfo?: lastStop = .usageLimit(at: at, turnId: turnId)
                case let info?: lastStop = .otherError(info)
                }
                activityAfterStop = false
            case let .userMessage(text, _, clientMessageId):
                userTexts.append(text)
                if let clientMessageId { clientIds.insert(clientMessageId) }
                activityAfterStop = true
            case .turnAborted:
                activityAfterStop = true
            case .other:
                break
            }
        }

        return SessionState(
            threadId: thread.id,
            cwd: thread.cwd.isEmpty ? metaCwd ?? "" : thread.cwd,
            originator: thread.originator ?? metaOriginator,
            lastStop: lastStop,
            userActivityAfterStop: activityAfterStop,
            lastActivityAt: lastActivity,
            lastTurnDurations: Array(durations.suffix(keptTurnDurations)),
            languageSample: LanguageSample.extract(from: userTexts),
            seenClientMessageIds: clientIds
        )
    }
}
