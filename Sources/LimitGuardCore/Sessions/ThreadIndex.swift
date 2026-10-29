import Foundation
import SQLite3

/// One row of Codex's `threads` table.
public struct ThreadRow: Equatable {
    public var id: String
    public var rolloutPath: URL
    public var cwd: String
    public var originator: String?
    public var updatedAt: Date
    public var archived: Bool
    public var title: String
    /// A thread spawned by another thread's agent (`source` is `{"subagent": …}`); it shares its
    /// parent's Terminal tab and is never typed into.
    public var isSubagent: Bool

    public init(
        id: String, rolloutPath: URL, cwd: String, originator: String?, updatedAt: Date, archived: Bool,
        title: String, isSubagent: Bool
    ) {
        self.id = id
        self.rolloutPath = rolloutPath
        self.cwd = cwd
        self.originator = originator
        self.updatedAt = updatedAt
        self.archived = archived
        self.title = title
        self.isSubagent = isSubagent
    }
}

public enum ThreadIndexError: Error, Equatable {
    case cannotOpen(String)
    case query(String)
}

/// Codex's thread index (`~/.codex/state_<n>.sqlite`), opened read-only for every query. The database
/// is live (WAL mode) while Codex runs, so it is never opened `immutable`.
public struct ThreadIndex {
    public let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    /// The `state_<n>.sqlite` with the highest `n` in `directory` (the number is a schema version
    /// that may change), or nil.
    public static func locateDatabase(
        in directory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex", directoryHint: .isDirectory)
    ) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let numbered = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite") else { return nil }
            guard let number = Int(name.dropFirst("state_".count).dropLast(".sqlite".count)) else { return nil }
            return (number, name)
        }
        return numbered.max { $0.0 < $1.0 }.map { directory.appending(path: $0.1) }
    }

    /// Threads updated at or after `updatedSince`, newest first.
    public func recentThreads(updatedSince: Date) throws -> [ThreadRow] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        // Read-only and without SQLITE_OPEN_CREATE: a missing file fails instead of being created.
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ThreadIndexError.cannotOpen(db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory")
        }
        sqlite3_busy_timeout(db, 2_000)

        let sql = """
            SELECT id, rollout_path, cwd, originator, COALESCE(updated_at_ms, updated_at * 1000) AS updated_ms,
                   archived, title, source
            FROM threads WHERE COALESCE(updated_at_ms, updated_at * 1000) >= ?1
            ORDER BY updated_ms DESC, id DESC
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ThreadIndexError.query(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(statement, 1, Int64((updatedSince.timeIntervalSince1970 * 1000).rounded(.down)))

        var rows: [ThreadRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ThreadIndexError.query(String(cString: sqlite3_errmsg(db))) }
            let originator = text(statement, 3)
            rows.append(ThreadRow(
                id: text(statement, 0) ?? "",
                rolloutPath: URL(fileURLWithPath: text(statement, 1) ?? ""),
                cwd: text(statement, 2) ?? "",
                originator: originator?.isEmpty == true ? nil : originator,
                updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 4)) / 1000),
                archived: sqlite3_column_int64(statement, 5) != 0,
                title: text(statement, 6) ?? "",
                isSubagent: text(statement, 7)?.contains(#""subagent""#) == true
            ))
        }
        return rows
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
