import Foundation
import SQLite3
import Testing
@testable import LimitGuardCore

@Suite("Sessions")
struct SessionTests {
    private static let threadId = "0a000000-0000-7000-8000-000000000001"
    private static let limitTurn = "0d000000-0000-7000-8000-00000000000b"

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso)!
    }

    private func thread(_ name: String, updatedAt: Date = Date(timeIntervalSince1970: 1_792_900_000)) -> ThreadRow {
        ThreadRow(
            id: Self.threadId, rolloutPath: fixtureURL(name), cwd: "/Users/tester/projects/sample",
            originator: "codex-tui", updatedAt: updatedAt, archived: false, title: "Sample", isSubagent: false
        )
    }

    private func state(_ name: String) throws -> SessionState {
        let row = thread(name)
        return SessionState.build(thread: row, events: try RolloutReader().tailEvents(of: row.rolloutPath))
    }

    // MARK: - Rollout reader + session state

    @Test func readsSessionMetaAndTurnEvents() throws {
        let events = try RolloutReader().tailEvents(of: fixtureURL("rollout-usage-limit.jsonl"))
        #expect(events.first == .sessionMeta(
            id: Self.threadId, cwd: "/Users/tester/projects/sample", originator: "codex-tui", cliVersion: "0.164.0"
        ))
        #expect(events.last == .taskComplete(
            turnId: Self.limitTurn, at: date("2026-10-26T11:01:24.250Z"), errorInfo: "usage_limit_exceeded"
        ))
        #expect(events.contains(.taskStarted(turnId: Self.limitTurn, at: date("2026-10-26T11:00:00.000Z"))))
        // The response_item text and the item_completed client id merge into one user message.
        let users = events.filter { if case .userMessage = $0 { return true } else { return false } }
        #expect(users.contains(.userMessage(
            text: "Now add a regression test.", at: date("2026-10-26T11:00:00.100Z"),
            clientMessageId: "1e000000-0000-4000-8000-000000000002"
        )))
        #expect(users.count == 3) // boilerplate + two real messages
    }

    @Test func finishedTurnIsNotAStop() throws {
        let s = try state("rollout-finished.jsonl")
        #expect(s.lastStop == .none)
        #expect(!s.userActivityAfterStop)
        #expect(s.threadId == Self.threadId && s.originator == "codex-tui")
        #expect(s.lastTurnDurations.count == 1 && abs(s.lastTurnDurations[0] - 120.4) < 0.001)
        #expect(s.seenClientMessageIds == ["1e000000-0000-4000-8000-000000000001"])
    }

    @Test func usageLimitStopDetected() throws {
        let s = try state("rollout-usage-limit.jsonl")
        #expect(s.lastStop == .usageLimit(at: date("2026-10-26T11:01:24.250Z"), turnId: Self.limitTurn))
        #expect(!s.userActivityAfterStop)
        #expect(s.lastActivityAt == date("2026-10-26T11:01:24.250Z"))
        #expect(s.lastTurnDurations.count == 2)
        #expect(abs(s.lastTurnDurations[1] - 84.25) < 0.001)
    }

    @Test func userMessageAfterStopMakesIneligible() throws {
        let s = try state("rollout-limit-then-user.jsonl")
        #expect(s.lastStop == .usageLimit(at: date("2026-10-26T11:01:24.250Z"), turnId: Self.limitTurn))
        #expect(s.userActivityAfterStop)
        #expect(s.lastActivityAt == date("2026-10-26T16:05:00.100Z"))
        #expect(s.seenClientMessageIds.contains("1e000000-0000-4000-8000-000000000003"))
    }

    @Test func newTurnOrAbortAfterStopCountsAsActivity() {
        let stop = RolloutEvent.taskComplete(turnId: "t1", at: Date(timeIntervalSince1970: 100), errorInfo: "usage_limit_exceeded")
        let row = thread("rollout-usage-limit.jsonl", updatedAt: Date(timeIntervalSince1970: 50))
        let started = SessionState.build(thread: row, events: [stop, .taskStarted(turnId: "t2", at: Date(timeIntervalSince1970: 200))])
        #expect(started.userActivityAfterStop)
        let aborted = SessionState.build(thread: row, events: [stop, .turnAborted(at: Date(timeIntervalSince1970: 300))])
        #expect(aborted.userActivityAfterStop && aborted.lastActivityAt == Date(timeIntervalSince1970: 300))
        let quiet = SessionState.build(thread: row, events: [stop, .other])
        #expect(!quiet.userActivityAfterStop && quiet.lastActivityAt == Date(timeIntervalSince1970: 100))
    }

    @Test func overloadedIsOtherError() throws {
        #expect(try state("rollout-overloaded.jsonl").lastStop == .otherError("server_overloaded"))
    }

    @Test func errorShapesAreTolerated() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.url.appending(path: "rollout.jsonl")
        let lines = [
            #"{"timestamp":"2026-10-26T10:00:00Z","type":"session_meta","payload":{"id":"a","cwd":"/x"}}"#,
            #"{"timestamp":"2026-10-26T10:00:01Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","error":{"message":"m"}}}"#,
            #"{"timestamp":"2026-10-26T10:00:02Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t2","error":{"codex_error_info":{"http_connection_failed":{"status":502}}}}}"#,
            "not json at all",
            #"{"timestamp":"2026-10-26T10:00:03Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t3","error":null}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        let events = try RolloutReader().tailEvents(of: url)
        #expect(events == [
            .sessionMeta(id: "a", cwd: "/x", originator: nil, cliVersion: nil),
            .taskComplete(turnId: "t1", at: date("2026-10-26T10:00:01.000Z"), errorInfo: "unknown"),
            .taskComplete(turnId: "t2", at: date("2026-10-26T10:00:02.000Z"), errorInfo: "http_connection_failed"),
            .taskComplete(turnId: "t3", at: date("2026-10-26T10:00:03.000Z"), errorInfo: nil),
        ])
    }

    @Test func onlyTheFirstLineIsTheThreadsSessionMeta() throws {
        // Forked (sub-agent) rollouts repeat the parent's session_meta on line 2.
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.url.appending(path: "rollout.jsonl")
        let lines = [
            #"{"timestamp":"2026-10-26T10:00:00.000Z","type":"session_meta","payload":{"id":"child","cwd":"/c","originator":"codex-tui","cli_version":"0.164.0"}}"#,
            #"{"timestamp":"2026-10-26T10:00:00.001Z","type":"session_meta","payload":{"id":"parent","cwd":"/p","originator":"codex-tui","cli_version":"0.163.0"}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        let events = try RolloutReader().tailEvents(of: url)
        #expect(events == [.sessionMeta(id: "child", cwd: "/c", originator: "codex-tui", cliVersion: "0.164.0"), .other])
    }

    @Test func tailReaderSkipsPartialFirstLine() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.url.appending(path: "rollout-big.jsonl")
        let meta = #"{"timestamp":"2026-10-26T10:00:00.000Z","type":"session_meta","payload":{"id":"big","cwd":"/b","originator":"codex-tui","cli_version":"0.164.0","base_instructions":""#
            + String(repeating: "i", count: 40_000) + #""}}"#
        var text = meta + "\n"
        let filler = #"{"timestamp":"2026-10-26T10:00:01.000Z","type":"response_item","payload":{"type":"reasoning","summary":[],"content":""#
            + String(repeating: "x", count: 900) + #""}}"#
        while text.utf8.count < 600_000 { text += filler + "\n" }
        text += #"{"timestamp":"2026-10-26T10:30:00.500Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"last","error":{"message":"m","codex_error_info":"usage_limit_exceeded"}}}"# + "\n"
        try Data(text.utf8).write(to: url)

        // A cut point that lands mid-line, never on a line start.
        let reader = RolloutReader()
        let events = try reader.tailEvents(of: url, maxBytes: 100_037)
        #expect(events.first == .sessionMeta(id: "big", cwd: "/b", originator: "codex-tui", cliVersion: "0.164.0"))
        #expect(events.last == .taskComplete(turnId: "last", at: date("2026-10-26T10:30:00.500Z"), errorInfo: "usage_limit_exceeded"))
        #expect(events.filter { $0 == .other }.count < 120)
        #expect(events.filter { if case .sessionMeta = $0 { return true } else { return false } }.count == 1)
        // Default window on the same file.
        #expect(try reader.tailEvents(of: url).last == events.last)

        // A window that starts exactly on a line start keeps that line.
        let lastLine = Data(text.utf8).split(separator: 0x0A).last!
        let exact = try reader.tailEvents(of: url, maxBytes: lastLine.count + 1)
        #expect(exact.count == 2 && exact.last == events.last)
    }

    @Test func tailReaderIgnoresAnUnfinishedLastLine() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let url = dir.url.appending(path: "rollout.jsonl")
        let text = #"{"timestamp":"2026-10-26T10:00:00Z","type":"session_meta","payload":{"id":"a","cwd":"/x"}}"# + "\n"
            + #"{"timestamp":"2026-10-26T10:00:01Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t","reason":"interrupted"}}"# + "\n"
            + #"{"timestamp":"2026-10-26T10:00:02Z","type":"event_msg","payload":{"type":"task_comp"#
        try Data(text.utf8).write(to: url)
        #expect(try RolloutReader().tailEvents(of: url).last == .turnAborted(at: date("2026-10-26T10:00:01.000Z")))
    }

    @Test func missingRolloutThrows() {
        #expect(throws: (any Error).self) {
            try RolloutReader().tailEvents(of: URL(fileURLWithPath: "/nonexistent/rollout.jsonl"))
        }
    }

    // MARK: - Language sample

    @Test func boilerplateIsExcludedFromLanguageSample() throws {
        let s = try state("rollout-boilerplate-user.jsonl")
        #expect(s.languageSample.contains("şu dosyayı düzelt"))
        #expect(!s.languageSample.contains("environment_context"))
        #expect(!s.languageSample.contains("AGENTS.md"))
        #expect(!s.languageSample.contains("codex_internal_context"))
        #expect(!s.languageSample.contains("user_instructions"))
    }

    @Test func languageSampleRules() {
        let long = String(repeating: "a", count: 4001)
        let sample = LanguageSample.extract(from: [
            "one", "two", "  <environment_context>x</environment_context>", "three", long,
            "# AGENTS.md instructions for /x\nrules", "four",
        ])
        #expect(sample == "two\nthree\nfour")
        let trimmed = LanguageSample.extract(from: [String(repeating: "b", count: 900), String(repeating: "c", count: 900)])
        #expect(trimmed.count == 1000)
        #expect(LanguageSample.extract(from: []) == "")
    }

    // MARK: - Thread index

    private func makeDatabase(at url: URL, rows: [(String, String, String, String?, Int64, Int64?, Int, String, String)]) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        var sql = """
            CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL, source TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL,
              archived INTEGER NOT NULL DEFAULT 0, originator TEXT, updated_at_ms INTEGER);
            """
        for (id, path, cwd, originator, updatedAt, updatedAtMs, archived, title, source) in rows {
            let o = originator.map { "'\($0)'" } ?? "NULL"
            let ms = updatedAtMs.map(String.init) ?? "NULL"
            sql += "INSERT INTO threads VALUES ('\(id)','\(path)',0,\(updatedAt),'\(source)','\(cwd)','\(title)',\(archived),\(o),\(ms));"
        }
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func threadIndexReadsReadOnly() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let dbURL = dir.url.appending(path: "state_5.sqlite")
        let subagentSource = #"{"subagent":{"thread_spawn":{"parent_thread_id":"p","depth":1}}}"#
        try makeDatabase(at: dbURL, rows: [
            ("new", "/r/new.jsonl", "/w", "codex-tui", 1_792_950_000, 1_792_950_000_250, 0, "New", "vscode"),
            ("legacy", "/r/legacy.jsonl", "/w2", nil, 1_792_940_000, nil, 1, "Legacy", "cli"),
            ("child", "/r/child.jsonl", "/w", "codex-tui", 1_792_945_000, 1_792_945_000_000, 0, "Child", subagentSource),
            ("old", "/r/old.jsonl", "/w", "codex-tui", 1_700_000_000, 1_700_000_000_000, 0, "Old", "vscode"),
        ])
        let before = try Data(contentsOf: dbURL)

        let rows = try ThreadIndex(databaseURL: dbURL).recentThreads(updatedSince: Date(timeIntervalSince1970: 1_792_000_000))
        #expect(rows == [
            ThreadRow(id: "new", rolloutPath: URL(fileURLWithPath: "/r/new.jsonl"), cwd: "/w", originator: "codex-tui",
                      updatedAt: Date(timeIntervalSince1970: 1_792_950_000.25), archived: false, title: "New", isSubagent: false),
            ThreadRow(id: "child", rolloutPath: URL(fileURLWithPath: "/r/child.jsonl"), cwd: "/w", originator: "codex-tui",
                      updatedAt: Date(timeIntervalSince1970: 1_792_945_000), archived: false, title: "Child", isSubagent: true),
            ThreadRow(id: "legacy", rolloutPath: URL(fileURLWithPath: "/r/legacy.jsonl"), cwd: "/w2", originator: nil,
                      updatedAt: Date(timeIntervalSince1970: 1_792_940_000), archived: true, title: "Legacy", isSubagent: false),
        ])
        #expect(try Data(contentsOf: dbURL) == before)

        let missing = dir.url.appending(path: "state_9.sqlite")
        #expect(throws: (any Error).self) {
            try ThreadIndex(databaseURL: missing).recentThreads(updatedSince: .distantPast)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func locatesHighestNumberedStateDatabase() throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        for name in ["state_5.sqlite", "state_10.sqlite", "state_9.sqlite", "state_11.sqlite-wal", "state_x.sqlite", "other.sqlite"] {
            try Data().write(to: dir.url.appending(path: name))
        }
        #expect(ThreadIndex.locateDatabase(in: dir.url)?.lastPathComponent == "state_10.sqlite")
        let empty = try TemporaryDirectory()
        defer { empty.remove() }
        #expect(ThreadIndex.locateDatabase(in: empty.url) == nil)
    }

    // MARK: - Scanner

    @Test func scannerKeepsRecentUnarchivedTuiThreads() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let dbURL = dir.url.appending(path: "state_5.sqlite")
        let limit = fixtureURL("rollout-usage-limit.jsonl").path
        let finished = fixtureURL("rollout-finished.jsonl").path
        let subagentSource = #"{"subagent":{"thread_spawn":{"parent_thread_id":"p","depth":1}}}"#
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let recent = Int64(now.timeIntervalSince1970) - 3_600
        try makeDatabase(at: dbURL, rows: [
            ("tui-limit", limit, "/w", "codex-tui", recent, recent * 1000, 0, "A", "vscode"),
            ("tui-finished", finished, "/w", "codex-tui", recent - 60, (recent - 60) * 1000, 0, "B", "cli"),
            ("desktop", limit, "/w", "codex_work_desktop", recent, recent * 1000, 0, "C", "vscode"),
            ("archived", limit, "/w", "codex-tui", recent, recent * 1000, 1, "D", "vscode"),
            ("stale", limit, "/w", "codex-tui", recent - 9 * 86_400, (recent - 9 * 86_400) * 1000, 0, "E", "vscode"),
            ("subagent", limit, "/w", "codex-tui", recent, recent * 1000, 0, "F", subagentSource),
            ("missing-file", "/nonexistent/rollout.jsonl", "/w", "codex-tui", recent, recent * 1000, 0, "G", "vscode"),
            ("null-originator", limit, "/w", nil, recent, recent * 1000, 0, "H", "vscode"),
        ])
        let scanner = SessionScanner(index: ThreadIndex(databaseURL: dbURL), reader: RolloutReader())
        let states = await scanner.scan(now: now)
        // A NULL originator falls back to the rollout's session_meta (codex-tui in the fixture).
        #expect(states.map(\.threadId).sorted() == ["null-originator", "tui-finished", "tui-limit"])
        let limited = try #require(states.first { $0.threadId == "tui-limit" })
        #expect(limited.lastStop == .usageLimit(at: date("2026-10-26T11:01:24.250Z"), turnId: Self.limitTurn))
        #expect(states.first { $0.threadId == "tui-finished" }?.lastStop == StopKind.none)
    }

    @Test func scannerWithMissingDatabaseReturnsNothing() async {
        let scanner = SessionScanner(
            index: ThreadIndex(databaseURL: URL(fileURLWithPath: "/nonexistent/state_5.sqlite")), reader: RolloutReader()
        )
        #expect(await scanner.scan(now: Date()).isEmpty)
    }
}
