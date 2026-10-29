import Foundation

/// The popover's status line (spec §4.2 item 1, §4.4), first matching state wins. Read-only mode is
/// a banner of its own, shown next to any of these.
public enum PopoverStatus: Equatable, Sendable {
    /// The Engine does not run yet (legal notice open, or still starting).
    case starting
    case codexMissing
    /// Codex is not signed in with ChatGPT: `codex login`.
    case notSignedIn
    /// The last limits read failed; the app-server is tried again on the next poll.
    case readFailed
    case reading
    case paused
    case noCodexTab
    /// Codex tabs are open; `guarded` of them are ticked.
    case watching(guarded: Int)

    public static func make(
        engineRunning: Bool, codexFound: Bool, hasSnapshot: Bool, readFailure: LimitsReadFailure?,
        isPaused: Bool, tabCount: Int, guardedCount: Int
    ) -> PopoverStatus {
        guard engineRunning else { return .starting }
        guard codexFound else { return .codexMissing }
        switch readFailure {
        case .notSignedIn?: return .notSignedIn
        case .unreachable?, .other?: return .readFailed
        case nil: break
        }
        guard hasSnapshot else { return .reading }
        if isPaused { return .paused }
        guard tabCount > 0 else { return .noCodexTab }
        return .watching(guarded: guardedCount)
    }
}
