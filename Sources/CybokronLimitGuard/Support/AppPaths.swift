import Foundation
import LimitGuardCore

/// Where the app keeps its files.
enum AppPaths {
    /// `~/Library/Application Support/Cybokron Limit Guard`.
    static var dataDirectory: URL { DataDirectory.url }

    static var settingsURL: URL { dataDirectory.appending(path: "settings.json") }
    static var activityURL: URL { dataDirectory.appending(path: "activity.json") }
    static var usageHistoryURL: URL { dataDirectory.appending(path: "usage-history.json") }
}
