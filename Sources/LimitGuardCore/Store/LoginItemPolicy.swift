import Foundation

/// Which running copy of the app may touch the login item.
public enum LoginItemPolicy {
    /// Only an installed copy (in /Applications or ~/Applications) syncs `SMAppService`; a debug
    /// build or a copy run from a build folder or a disk image never registers or removes anything.
    public static func shouldSync(
        bundleURL: URL, isDebugBuild: Bool,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard !isDebugBuild, bundleURL.pathExtension == "app" else { return false }
        let path = bundleURL.standardizedFileURL.path
        let userApplications = home.standardizedFileURL.path + "/Applications/"
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApplications)
    }
}
