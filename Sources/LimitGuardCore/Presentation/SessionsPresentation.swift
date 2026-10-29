import Foundation

/// One Codex tab as a row of the popover's "Codex sessions" section (spec §7.3, "Guarded tabs").
public struct SessionRow: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        /// Nothing waits in this tab.
        case idle
        /// Its conversation waits on the limit and continues on its own.
        case waitingGuarded
        /// Its conversation waits on the limit, but the tab is not ticked: "Continue now" only.
        case waitingNotGuarded
        /// A conversation waits on the limit and could be in this tab, but which one is unclear: by hand only.
        case ambiguous
    }

    public var id: TabRef { ref }
    public var ref: TabRef
    /// The folder name (Codex's tab title).
    public var title: String
    public var cwd: String?
    public var tty: String
    public var isGuarded: Bool
    /// The waiting thread mapped to this tab.
    public var threadId: String?
    /// The first 8 characters of `threadId`.
    public var shortThreadId: String?
    /// The mapped thread's title, when the index has one.
    public var threadTitle: String?
    public var state: State
}

public enum SessionsPresentation {
    static let shortIdLength = 8

    /// `tabs` and `sessions` as the Engine publishes them. A tab without a thread is ambiguous when a
    /// waiting TUI conversation no tab claims has the tab's folder, or the tab's folder is unknown.
    public static func rows(tabs: [EngineTab], sessions: [SessionState], snapshot: AccountSnapshot?, now: Date) -> [SessionRow] {
        let claimed = Set(tabs.compactMap(\.threadId))
        let unclaimedWaiting: [SessionState] = snapshot.map { read in
            sessions.filter {
                $0.originator == TabMatcher.tuiOriginator && !claimed.contains($0.threadId)
                    && ContinuePolicy.isWaitingOnUsageLimit(session: $0, snapshot: read, stopInfo: nil, now: now)
            }
        } ?? []
        let titles = Dictionary(sessions.compactMap { session in session.title.map { (session.threadId, $0) } },
                                uniquingKeysWith: { first, _ in first })
        let unclaimedFolders = Set(unclaimedWaiting.map { TabMatcher.normalize($0.cwd) })

        return tabs.map { entry in
            let tab = entry.tab
            let state: SessionRow.State
            if entry.threadId != nil {
                state = entry.isGuarded ? .waitingGuarded : .waitingNotGuarded
            } else if let cwd = tab.cwd {
                state = unclaimedFolders.contains(TabMatcher.normalize(cwd)) ? .ambiguous : .idle
            } else {
                state = unclaimedWaiting.isEmpty ? .idle : .ambiguous
            }
            return SessionRow(
                ref: tab.ref, title: tab.title, cwd: tab.cwd, tty: tab.ref.tty, isGuarded: entry.isGuarded,
                threadId: entry.threadId, shortThreadId: entry.threadId.map { String($0.prefix(shortIdLength)) },
                threadTitle: entry.threadId.flatMap { titles[$0] }, state: state)
        }
    }
}
