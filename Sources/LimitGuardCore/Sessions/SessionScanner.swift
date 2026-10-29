import Foundation

/// Builds the state of every recent Codex TUI thread from the thread index and rollout tails.
public actor SessionScanner {
    static let tuiOriginator = "codex-tui"
    static let maxAge: TimeInterval = 8 * 24 * 3_600

    private let index: ThreadIndex
    private let reader: RolloutReader
    /// Reads a rollout's last real user messages (`RolloutReader.recentUserMessages`); injectable for tests.
    private let readUserMessages: (URL) throws -> [String]
    /// Language samples of waiting threads by stop. The messages before a given stop never change,
    /// even while the file keeps growing.
    private var samples: [StopKey: String] = [:]

    private struct StopKey: Hashable {
        let threadId: String
        let turnId: String
    }

    public init(index: ThreadIndex, reader: RolloutReader) {
        self.init(index: index, reader: reader, readUserMessages: { try reader.recentUserMessages(of: $0) })
    }

    init(index: ThreadIndex, reader: RolloutReader, readUserMessages: @escaping (URL) throws -> [String]) {
        self.index = index
        self.reader = reader
        self.readUserMessages = readUserMessages
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
            var state = SessionState.build(thread: row, events: events)
            guard state.originator == Self.tuiOriginator else { continue }
            // Only a thread still waiting on the limit needs the sample; once the owner or a continue
            // has started a turn, the tail holds the newest messages anyway.
            if case let .usageLimit(_, turnId) = state.lastStop, !state.userActivityAfterStop,
               let sample = languageSample(of: StopKey(threadId: row.id, turnId: turnId), url: row.rolloutPath) {
                state.languageSample = sample
            }
            states.append(state)
        }
        let ids = Set(rows.map(\.id))
        samples = samples.filter { ids.contains($0.key.threadId) }
        return states.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// The tail rarely holds the owner's messages of a long turn, so a stopped thread's sample is
    /// read further back, once per stop.
    private func languageSample(of key: StopKey, url: URL) -> String? {
        if let cached = samples[key] { return cached }
        guard let messages = try? readUserMessages(url) else { return nil }
        let sample = LanguageSample.extract(from: messages)
        samples[key] = sample
        return sample
    }
}
