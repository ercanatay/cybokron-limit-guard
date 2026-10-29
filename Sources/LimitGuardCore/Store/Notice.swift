import Foundation

/// First-run notice gate: shown until the user accepted the current notice version.
public enum Notice {
    public static let currentVersion = 1

    public static func mustShow(settings: Settings) -> Bool {
        guard let accepted = settings.noticeAcceptedVersion else { return true }
        return accepted < currentVersion
    }
}
