import Foundation

/// The app's name, version and links, read from the bundle.
enum AppInfo {
    static let name = "Cybokron Limit Guard"
    static let repositoryURL = URL(string: "https://github.com/ercanatay/cybokron-limit-guard")!
    static let licenseURL = URL(string: "https://github.com/ercanatay/cybokron-limit-guard/blob/main/LICENSE")!

    /// The marketing version, e.g. "0.1.0".
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var copyright: String? {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
    }
}
