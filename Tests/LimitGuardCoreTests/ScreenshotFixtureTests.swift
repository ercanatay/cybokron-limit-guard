#if DEBUG
import Foundation
import Testing
@testable import LimitGuardCore

@Suite("Screenshot fixture")
struct ScreenshotFixtureTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var fixture: ScreenshotFixture { ScreenshotFixture(now: now, home: "/Users/demo") }

    @Test func limitsDecodeToTheShownSnapshot() throws {
        let (snapshot, health) = try AccountSnapshot.decode(from: Data(fixture.limitsResult.utf8), readAt: now)
        #expect(health == .full)
        #expect(snapshot.ordinaryUsageAllowed == true)
        #expect(snapshot.fiveHour?.usedPercent == 42)
        #expect(snapshot.fiveHour?.resetsAt == now.addingTimeInterval(2 * 3600 + 10 * 60))
        #expect(snapshot.weekly?.usedPercent == 63)
        #expect(snapshot.weekly?.resetsAt == now.addingTimeInterval(4 * 86_400 + 6 * 3600))
        #expect(snapshot.planType == "plus")
        #expect(snapshot.availableCredits.map(\.title) == [ScreenshotFixture.creditTitle, ScreenshotFixture.creditTitle])
        #expect(snapshot.availableCredits.map(\.expiresAt) == [now.addingTimeInterval(20 * 3600), now.addingTimeInterval(9 * 86_400)])
    }

    @Test func usageAndHistoryCoverThirtyDays() throws {
        let report = try UsageReport.decode(from: Data(fixture.usageResult.utf8))
        #expect(report.daily?.count == 30)
        #expect(report.daily?.last?.day == ChartData.today(now))
        let history = fixture.history
        #expect(history.first.map { now.timeIntervalSince($0.date) <= UsageHistory.retention } == true)
        #expect(history.last?.date == now)
        #expect(history.last?.fiveHour == 42)
        #expect(history.last?.weekly == 63)
        #expect(history.allSatisfy { ($0.fiveHour ?? 0) <= 100 && ($0.weekly ?? 0) <= 100 })
    }

    @Test func tabsMapToTheirSessions() {
        let fixture = fixture
        let map = TabMatcher.match(
            tabs: fixture.tabs, threads: fixture.sessions, loadedThreadCwds: fixture.loadedThreadCwds,
            knownThreadIds: Set(fixture.sessions.map(\.threadId)))
        #expect(map[fixture.guardedTab.ref] == ScreenshotFixture.guardedThread)
        #expect(map[fixture.waitingTab.ref] == ScreenshotFixture.waitingThread)
        #expect(fixture.guardedTab.cwd == "/Users/demo/Projects/my-app")
    }

    /// The Engine on the fixture's fakes shows what the popover screenshot needs, and never spends.
    @MainActor
    @Test func engineCountsDownForTheGuardedTab() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let fixture = ScreenshotFixture(now: Date(), home: "/Users/demo")
        try fixture.seed(into: dir.url)
        let settings = fixture.settings
        let engine = Engine(Engine.Dependencies(
            clock: SystemClock(), environment: ScreenshotEnvironment(fixture: fixture),
            account: CodexAccountService(
                client: AppServerClient(
                    transportFactory: { ScreenshotAppServer(fixture: fixture) }, clientName: "test", clientVersion: "0"),
                now: { Date() }),
            sessions: ScreenshotSessions(fixture: fixture), delivery: ScreenshotDelivery(fixture: fixture),
            dataDirectory: dir.url, settings: { settings }))
        await engine.tick()

        guard case let .countdown(_, threadId, text)? = engine.nextAction?.kind else {
            Issue.record("no countdown: \(String(describing: engine.nextAction))")
            return
        }
        #expect(threadId == ScreenshotFixture.guardedThread)
        #expect(text == "continue")
        #expect(engine.tabs.map(\.isGuarded) == [true, false])
        #expect(engine.tabs.map(\.threadId) == [ScreenshotFixture.guardedThread, ScreenshotFixture.waitingThread])
        // The first tick adds only the countdown to the seeded activity.
        let entries = try ActivityLog(url: dir.url.appending(path: Engine.activityFileName)).entries()
        #expect(entries.count == fixture.activity.count + 1)
        #expect(entries.last?.kind == .continueScheduled)
    }

    @Test func appServerRefusesTheConsume() async throws {
        let server = ScreenshotAppServer(fixture: fixture)
        let reply = AsyncStream<String> { continuation in
            server.onLine = { continuation.yield(String(decoding: $0, as: UTF8.self)) }
        }
        try server.send(Data(#"{"id":7,"method":"account/rateLimitResetCredit/consume","params":{"creditId":"demo-credit-1"}}"#.utf8))
        var iterator = reply.makeAsyncIterator()
        let line = try #require(await iterator.next())
        #expect(line.contains(#""id":7"#))
        #expect(line.contains(#""error""#))
        #expect(!line.contains(#""result""#))
    }
}
#endif
