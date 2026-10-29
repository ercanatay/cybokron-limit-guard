import Foundation

/// Where the app keeps its files.
enum AppPaths {
    /// `~/Library/Application Support/Cybokron Limit Guard`.
    static var dataDirectory: URL {
        #if DEBUG
        // Debug builds only: lets a manual run use a temporary folder instead of the real data.
        if let override = ProcessInfo.processInfo.environment["CYBOKRON_LG_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Cybokron Limit Guard", directoryHint: .isDirectory)
    }

    static var settingsURL: URL { dataDirectory.appending(path: "settings.json") }
    static var activityURL: URL { dataDirectory.appending(path: "activity.json") }
    static var usageHistoryURL: URL { dataDirectory.appending(path: "usage-history.json") }
}
