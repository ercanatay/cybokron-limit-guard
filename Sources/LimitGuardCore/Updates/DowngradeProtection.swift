import Foundation

/// Going back, from "Other Versions…", to an older version than the one running.
///
/// An older version may not understand the newer version's data files, so before it's installed
/// every JSON file of the data folder is copied next to itself as
/// `<name>.pre-downgrade-<timestamp>.json` (`makePreDowngradeCopies`). A copy failing throws, and
/// nothing is installed.
///
/// `UpdateInstaller` replaces the app only and never reads the data; this happens around it.
public enum DowngradeProtection {
    /// Whether installing `target` while `current` runs goes back to an older version
    /// (`current` is `nil` when the running app has no version, as in development).
    public static func applies(installing target: SemanticVersion, over current: SemanticVersion?) -> Bool {
        current.map { target < $0 } ?? true
    }

    /// The app's data folder, `~/Library/Application Support/Cybokron Limit Guard`.
    public static var dataDirectory: URL { JSONFileSupport.directoryURL }

    /// The timestamp in the copies' names: `yyyyMMdd-HHmmss`, local time.
    public static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Copies the data files of `directory` aside before `target` is installed over `current`, when
    /// that goes back to an older version. A folder that doesn't exist yet has nothing to copy.
    /// - Returns: Whether copies were made.
    @discardableResult
    public static func preserveCopies(
        in directory: URL = DowngradeProtection.dataDirectory,
        installing target: SemanticVersion,
        over current: SemanticVersion?,
        now: Date = Date()
    ) throws -> Bool {
        guard applies(installing: target, over: current) else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        try makePreDowngradeCopies(in: directory, timestamp: timestamp(now))
        return true
    }

    /// Runs `replace` only after the copies of `preserveCopies` are in place: when they fail, the
    /// error is thrown and `replace` never runs, so nothing is installed.
    public static func replacing<T>(
        in directory: URL = DowngradeProtection.dataDirectory,
        installing target: SemanticVersion,
        over current: SemanticVersion?,
        now: Date = Date(),
        replace: () async throws -> T
    ) async throws -> T {
        try preserveCopies(in: directory, installing: target, over: current, now: now)
        return try await replace()
    }
}
