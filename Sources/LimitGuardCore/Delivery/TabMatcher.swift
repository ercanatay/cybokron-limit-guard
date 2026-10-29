import Foundation

/// A Terminal tab running a Codex TUI, as seen from its process (no Terminal scripting in Phase 1):
/// `ref` carries the tty with window id and tab index 0 when they are unknown.
public struct TerminalTab: Equatable, Sendable {
    public var ref: TabRef
    /// The folder name of `cwd` (Codex sets the tab title to it), else the tty name.
    public var title: String
    public var cwd: String?
    public var codexPid: Int32?
    public var busy: Bool

    public init(ref: TabRef, title: String, cwd: String?, codexPid: Int32?, busy: Bool) {
        self.ref = ref
        self.title = title
        self.cwd = cwd
        self.codexPid = codexPid
        self.busy = busy
    }
}

/// Pairs Terminal tabs with threads (spec §7.3, spike S2): by the TUI process's cwd against the
/// loaded thread's cwd. Anything ambiguous is left out (D18): the caller notifies instead of continuing.
public enum TabMatcher {
    public static let tuiOriginator = "codex-tui"

    /// `tabs`: every Terminal tab with a Codex TUI, guarded or not, so that same-cwd duplicates are seen.
    /// `threads`: the eligible threads. `loadedThreadCwds`: threadId → cwd from `thread/loaded/list` +
    /// `thread/read` (non-ephemeral). Only loaded TUI threads and tabs with a Codex process take part.
    public static func match(tabs: [TerminalTab], threads: [SessionState], loadedThreadCwds: [String: String]) -> [TabRef: String] {
        let candidateTabs = tabs.filter { $0.codexPid != nil }
        let loaded = loadedThreadCwds.mapValues(normalize)
        let candidates = threads.filter { $0.originator == tuiOriginator && loaded[$0.threadId] != nil }
        let candidateIds = Set(candidates.map(\.threadId))

        // Rule 1: one tab, one thread — paired unless the tab's cwd is known and says otherwise.
        if candidateTabs.count == 1, candidates.count == 1 {
            let tab = candidateTabs[0]
            let thread = candidates[0].threadId
            if let cwd = tab.cwd, normalize(cwd) != loaded[thread] { return [:] }
            return [tab.ref: thread]
        }

        // Rule 2: the cwd names exactly one tab and exactly one loaded thread, and that thread is a candidate.
        var tabsByCwd: [String: [TerminalTab]] = [:]
        for tab in candidateTabs {
            guard let cwd = tab.cwd else { continue }
            tabsByCwd[normalize(cwd), default: []].append(tab)
        }
        var threadsByCwd: [String: [String]] = [:]
        for (thread, cwd) in loaded { threadsByCwd[cwd, default: []].append(thread) }

        var map: [TabRef: String] = [:]
        for (cwd, tabsHere) in tabsByCwd {
            guard tabsHere.count == 1, let threadsHere = threadsByCwd[cwd], threadsHere.count == 1,
                  candidateIds.contains(threadsHere[0]) else { continue }
            map[tabsHere[0].ref] = threadsHere[0]
        }
        return map
    }

    /// The thread for `tab` when it is the only Codex tab.
    public static func match(single tab: TerminalTab, threads: [SessionState], loadedThreadCwds: [String: String]) -> String? {
        match(tabs: [tab], threads: threads, loadedThreadCwds: loadedThreadCwds)[tab.ref]
    }

    static func normalize(_ path: String) -> String {
        let standard = (path as NSString).standardizingPath
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }
}
