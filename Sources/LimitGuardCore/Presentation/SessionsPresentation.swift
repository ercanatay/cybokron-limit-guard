import Foundation

/// One Codex tab as a row of the popover's "Codex sessions" section (spec §7.3, "Guarded tabs").
public struct SessionRow: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        /// Nothing waits in this tab.
        case idle
        /// Its conversation waits on the limit and continues on its own.
        case waitingGuarded
        /// A continue was sent; Codex has not shown it yet.
        case confirming
        /// The continue was not confirmed in time and is never resent on its own: "Send again".
        case unconfirmed
        /// Guarded, but this stop is not continued on its own any more: "Continue now" only.
        case settled
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
    /// The mapped thread's title, when the index has one.
    public var threadTitle: String?
    public var state: State
}

public enum SessionsPresentation {

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
                switch entry.continueStatus {
                case .confirming: state = .confirming
                case .unconfirmed: state = .unconfirmed
                case .settled: state = entry.isGuarded ? .settled : .waitingNotGuarded
                case nil: state = entry.isGuarded ? .waitingGuarded : .waitingNotGuarded
                }
            } else if let cwd = tab.cwd {
                state = unclaimedFolders.contains(TabMatcher.normalize(cwd)) ? .ambiguous : .idle
            } else {
                state = unclaimedWaiting.isEmpty ? .idle : .ambiguous
            }
            return SessionRow(
                ref: tab.ref, title: tab.title, cwd: tab.cwd, tty: tab.ref.tty, isGuarded: entry.isGuarded,
                threadId: entry.threadId,
                threadTitle: entry.threadId.flatMap { titles[$0] }.flatMap(displayName), state: state)
        }
    }

    static let maxNameLength = 40

    /// A thread title worth showing on a row: a real short name. A long or multi-line title is the
    /// preview of the first message, which is never shown.
    public static func displayName(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= maxNameLength,
              !trimmed.contains(where: \.isNewline), !trimmed.hasSuffix("…") else { return nil }
        return trimmed
    }

    /// The one line of text under a row.
    public enum Note: Equatable, Sendable {
        case none
        case continuesAutomatically
        case pausedResumeContinues
        case autoContinueOff
        case confirming
        case unconfirmed
        case settled
        case waitingNotGuarded
        case ambiguous
    }

    /// What a row says about itself. Only a guarded row that waits for the app to act depends on
    /// whether the app is paused or auto-continue is off.
    public static func note(state: SessionRow.State, paused: Bool, autoContinue: Bool) -> Note {
        switch state {
        case .idle: return .none
        case .waitingGuarded:
            if !autoContinue { return .autoContinueOff }
            return paused ? .pausedResumeContinues : .continuesAutomatically
        case .confirming: return .confirming
        case .unconfirmed: return .unconfirmed
        case .settled: return .settled
        case .waitingNotGuarded: return .waitingNotGuarded
        case .ambiguous: return .ambiguous
        }
    }
}
