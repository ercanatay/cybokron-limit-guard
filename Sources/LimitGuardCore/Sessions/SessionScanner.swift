import Foundation

/// Builds the state of every recent Codex TUI thread from the thread index and rollout tails.
public actor SessionScanner {
    static let tuiOriginator = "codex-tui"
    static let maxAge: TimeInterval = 8 * 24 * 3_600

    private let index: ThreadIndex
    private let reader: RolloutReader

    public init(index: ThreadIndex, reader: RolloutReader) {
        self.index = index
        self.reader = reader
    }

    /// Threads from the Terminal TUI (`originator == "codex-tui"`, from the row or else the rollout's
    /// `session_meta`), not archived, not sub-agents, updated within 8 days; newest activity first.
    /// An unreadable index yields no sessions; an unreadable rollout drops that thread.
    public func scan(now: Date) async -> [SessionState] {
        guard let rows = try? index.recentThreads(updatedSince: now.addingTimeInterval(-Self.maxAge)) else { return [] }
        var states: [SessionState] = []
        for row in rows where !row.archived && !row.isSubagent {
            if let originator = row.originator, originator != Self.tuiOriginator { continue }
            guard let events = try? reader.tailEvents(of: row.rolloutPath) else { continue }
            let state = SessionState.build(thread: row, events: events)
            guard state.originator == Self.tuiOriginator else { continue }
            states.append(state)
        }
        return states.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }
}
