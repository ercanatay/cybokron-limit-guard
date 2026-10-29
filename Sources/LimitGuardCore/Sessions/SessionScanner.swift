import Foundation

/// Builds the state of every recent Codex TUI thread from the thread index and rollout tails.
public actor SessionScanner {
    static let tuiOriginator = "codex-tui"
    static let maxAge: TimeInterval = 8 * 24 * 3_600

    private let index: ThreadIndex
    private let reader: RolloutReader
    /// Language samples of stopped threads by rollout path, valid while the file size is unchanged.
    private var samples: [URL: (size: UInt64, sample: String)] = [:]

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
            var state = SessionState.build(thread: row, events: events)
            guard state.originator == Self.tuiOriginator else { continue }
            if case .usageLimit = state.lastStop, let sample = languageSample(of: row.rolloutPath) {
                state.languageSample = sample
            }
            states.append(state)
        }
        let paths = Set(rows.map(\.rolloutPath))
        samples = samples.filter { paths.contains($0.key) }
        return states.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// The tail rarely holds the owner's messages of a long turn, so a stopped thread's sample is
    /// read further back; a stopped rollout does not grow, so the result is cached by size.
    private func languageSample(of url: URL) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            return nil
        }
        if let cached = samples[url], cached.size == size.uint64Value { return cached.sample }
        guard let messages = try? reader.recentUserMessages(of: url) else { return nil }
        let sample = LanguageSample.extract(from: messages)
        samples[url] = (size.uint64Value, sample)
        return sample
    }
}
