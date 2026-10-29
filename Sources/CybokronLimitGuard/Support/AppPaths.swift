import Foundation

/// Where the app keeps its files.
enum AppPaths {
    /// `~/Library/Application Support/Cybokron Limit Guard`.
    static var dataDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Cybokron Limit Guard", directoryHint: .isDirectory)
    }

    static var settingsURL: URL { dataDirectory.appending(path: "settings.json") }
}
