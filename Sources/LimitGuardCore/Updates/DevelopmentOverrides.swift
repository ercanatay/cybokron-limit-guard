import Foundation

/// Environment variables for trying the updater and Settings → Changelog out locally — another
/// release feed (`CYBOKRON_UPDATE_FEED_URL`, `CYBOKRON_RELEASES_FEED_URL`,
/// `CYBOKRON_CHANGELOG_FEED_URL`) or a dry run (`CYBOKRON_UPDATE_DRY_RUN`). Only development
/// builds (the `DEBUG` compilation condition: SwiftPM's and Xcode's Debug configuration, and the
/// tests) read them; release builds ignore them, so nothing outside the app can point a shipped
/// copy at another update server.
public enum DevelopmentOverrides {
    /// Whether this build reads the variables: `true` for Debug builds, `false` for Release.
    public static var areEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The value of `variable` in `environment`; always `nil` when `enabled` is `false` (as in
    /// release builds).
    public static func value(
        _ variable: String,
        in environment: [String: String] = ProcessInfo.processInfo.environment,
        enabled: Bool = DevelopmentOverrides.areEnabled
    ) -> String? {
        guard enabled else { return nil }
        return environment[variable]
    }
}
