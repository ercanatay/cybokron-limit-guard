import Foundation

/// Whether `settings.json` can be used.
public enum SettingsFileStatus: Equatable, Sendable {
    /// Read fine, or not written yet.
    case usable
    /// Written by a newer app version: shown read-only and never touched.
    case newerSchema
    /// Broken (not JSON, wrong shape, wrong types): nothing can be saved until it is reset.
    case unreadable
}

public enum SettingsRecoveryError: Error, Equatable {
    /// Only an unreadable file is reset; a usable or newer one is left alone.
    case notUnreadable(SettingsFileStatus)
}

/// "Reset settings…" for an unreadable `settings.json`: the broken file is kept next to it as
/// `settings.corrupt-<timestamp>.json`, then the defaults are written.
public enum SettingsRecovery {
    public static func status(of store: JSONStore<Settings>) -> SettingsFileStatus {
        do {
            _ = try store.load()
            return .usable
        } catch StoreError.newerSchema {
            return .newerSchema
        } catch {
            return .unreadable
        }
    }

    /// Returns the backup's URL. The status is checked again here, so a file that became usable or
    /// newer in the meantime is never moved.
    @discardableResult
    public static func resetUnreadable(store: JSONStore<Settings>, defaults: Settings = Settings(), now: Date = Date()) throws -> URL {
        let current = status(of: store)
        guard current == .unreadable else { throw SettingsRecoveryError.notUnreadable(current) }
        let backup = backupURL(for: store.url, now: now)
        try FileManager.default.moveItem(at: store.url, to: backup)
        try store.save(defaults)
        return backup
    }

    /// `settings.corrupt-20261029-194320.json`, with `-2`, `-3`, … when that name is taken.
    static func backupURL(for url: URL, now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(url.deletingPathExtension().lastPathComponent).corrupt-\(formatter.string(from: now))"
        let dir = url.deletingLastPathComponent()
        var candidate = dir.appendingPathComponent("\(base).json")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(suffix).json")
            suffix += 1
        }
        return candidate
    }
}
