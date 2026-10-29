import Foundation
import LimitGuardCore

/// Temporary source for the chart window until the engine owns the live data: the stored
/// `usage-history.json` plus one read-only `account/usage/read` and `account/rateLimits/read`
/// through a private `codex app-server` client. Never calls the reset-credit consume method.
enum StoredChartFeed {
    static func load() async -> UsageChartContent {
        let samples = (try? UsageHistory(url: AppPaths.usageHistoryURL).samples()) ?? []
        var content = UsageChartContent(report: nil, samples: samples, weeklyResetsAt: nil, now: Date())
        let override = (try? JSONStore<Settings>(url: AppPaths.settingsURL, schemaVersion: 1).load())?.codexPathOverride
        guard let codex = CodexLocator().resolve(override: override) else { return content }
        let client = AppServerClient(
            transportFactory: { ProcessTransport(executable: codex, arguments: ["app-server"]) },
            clientName: "cybokron-limit-guard",
            clientVersion: AppInfo.version)
        let service = CodexAccountService(client: client, now: { Date() })
        content.report = try? await service.readUsage()
        if let (snapshot, _) = try? await service.readLimits() {
            content.weeklyResetsAt = snapshot.weekly?.resetsAt
        }
        await client.shutdown()
        content.now = Date()
        return content
    }
}
