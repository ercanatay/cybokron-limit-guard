import AppKit
import Foundation
import LimitGuardCore
import UserNotifications

/// Gathers what the diagnostics checks need from the system and hands it to `DiagnosticsCore`.
/// It reads no credential (sign-in is judged from `account/rateLimits/read`), only reads
/// `~/.codex/config.toml`, and never makes macOS ask for a permission.
enum Diagnostics {
    /// The newest Codex release Limit Guard was tested against.
    static let lastTestedCodexVersion = "0.165.0"

    static func run(keepAwakeActive: Bool = false) async -> [DiagnosticItem] {
        let override = (try? JSONStore<Settings>(url: AppPaths.settingsURL, schemaVersion: 1).load())?.codexPathOverride
        let locator = CodexLocator()
        let codex = locator.resolve(override: override)
        var version: String?
        var limits = LimitsProbe.notRun
        if let codex {
            version = await locator.version(of: codex)
            limits = await probeLimits(codex: codex)
        }
        return DiagnosticsCore.items(DiagnosticsCore.Inputs(
            codexVersion: version,
            codexFound: codex != nil,
            lastTestedCodexVersion: lastTestedCodexVersion,
            limits: limits,
            configText: readCodexConfig(),
            notifications: await notificationState(),
            keepAwakeActive: keepAwakeActive))
    }

    private static func probeLimits(codex: URL) async -> LimitsProbe {
        let client = AppServerClient(
            transportFactory: { ProcessTransport(executable: codex, arguments: ["app-server"]) },
            clientName: "cybokron-limit-guard",
            clientVersion: AppInfo.version)
        let service = CodexAccountService(client: client, now: { Date() })
        defer { Task { await client.shutdown() } }
        do {
            let (_, health) = try await service.readLimits()
            return .read(health)
        } catch {
            return LimitsProbe(error: error)
        }
    }

    private static func readCodexConfig() -> String? {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
        return try? String(contentsOfFile: (home as NSString).appendingPathComponent("config.toml"), encoding: .utf8)
    }

    private static func notificationState() async -> PermissionState {
        guard Bundle.main.bundleIdentifier != nil else { return .unavailable }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }
}
