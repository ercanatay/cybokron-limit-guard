import Foundation

/// The one place that decides where the app keeps its files:
/// `~/Library/Application Support/Cybokron Limit Guard`. Debug builds may point it elsewhere with
/// `CYBOKRON_LG_DATA_DIR`, so a manual run never touches the owner's real folder; release builds
/// ignore the variable.
public enum DataDirectory {
    public static let overrideVariable = "CYBOKRON_LG_DATA_DIR"

    public static var url: URL {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return resolve(environment: ProcessInfo.processInfo.environment, honoursOverride: debug)
    }

    /// `environment` and `honoursOverride` are parameters so tests do not depend on the process.
    public static func resolve(
        environment: [String: String], honoursOverride: Bool,
        base: URL = URL.applicationSupportDirectory
    ) -> URL {
        if honoursOverride, let value = environment[overrideVariable], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        return base.appending(path: "Cybokron Limit Guard", directoryHint: .isDirectory)
    }
}
