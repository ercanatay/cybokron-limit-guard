#if DEBUG
import Foundation

/// Made-up data for the README screenshots (debug builds only, `-LGScreenshotScene`): one account
/// snapshot, two Codex tabs, a few activity entries and 30 days of usage. Nothing here comes from a
/// real account; every date is relative to `now`.
public struct ScreenshotFixture: Sendable {
    public let now: Date
    /// The home folder the tabs' folders live in, so the popover shows them as `~/Projects/…`.
    public let home: String

    public static let guardedThread = "019a0000-0000-7000-8000-00000000a001"
    public static let waitingThread = "019a0000-0000-7000-8000-00000000a002"
    public static let creditTitle = "Full reset (Weekly + 5 hr)"
    public static let codexVersion = "codex-cli 0.50.0"

    public init(now: Date, home: String) {
        self.now = now
        self.home = home
    }

    // MARK: Account

    public var fiveHourResetsAt: Date { now.addingTimeInterval(2 * 3600 + 10 * 60) }
    public var weeklyResetsAt: Date { now.addingTimeInterval(4 * 86_400 + 6 * 3600) }

    /// The `result` of `account/rateLimits/read`: 42 % / 63 % used, gate open, two credits, plan "plus".
    public var limitsResult: String {
        let credits: [[String: Any]] = [
            credit(id: "demo-credit-1", grantedDaysAgo: 6, expiresIn: 20 * 3600),
            credit(id: "demo-credit-2", grantedDaysAgo: 2, expiresIn: 9 * 86_400),
        ]
        let root: [String: Any] = [
            "accountId": "demo-account",
            "ordinaryUsageAllowed": true,
            "rateLimits": [
                "planType": "plus",
                "primary": ["usedPercent": 42, "windowDurationMins": 300, "resetsAt": seconds(fiveHourResetsAt)],
                "secondary": ["usedPercent": 63, "windowDurationMins": 10_080, "resetsAt": seconds(weeklyResetsAt)],
            ],
            "rateLimitResetCredits": ["availableCount": credits.count, "credits": credits],
        ]
        return json(root)
    }

    /// The `result` of `account/usage/read`: 30 daily token buckets (UTC days, as Codex sends them).
    public var usageResult: String {
        let buckets = dailyTokens.map { ["startDate": $0.day, "tokens": $0.tokens] as [String: Any] }
        let peak = dailyTokens.map(\.tokens).max() ?? 0
        return json([
            "dailyUsageBuckets": buckets,
            "summary": ["peakDailyTokens": peak, "currentStreakDays": 12],
        ])
    }

    var dailyTokens: [DailyUsage] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let today = calendar.startOfDay(for: now)
        return (0..<30).reversed().compactMap { offset -> DailyUsage? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let weekday = calendar.component(.weekday, from: date)
            let weekend = weekday == 1 || weekday == 7
            let base: Double = weekend ? 4_000_000 : 18_000_000
            let tokens = Int64(base * (0.55 + 0.9 * Self.noise(offset)))
            return DailyUsage(day: ChartData.today(date), tokens: tokens)
        }
    }

    // MARK: Codex tabs and sessions

    public var guardedTab: TerminalTab {
        tab(window: 1, tty: "/dev/ttys004", pid: 40_404, folder: "my-app", started: "Wed Oct 29 09:12:03 2026")
    }

    public var waitingTab: TerminalTab {
        tab(window: 2, tty: "/dev/ttys006", pid: 40_606, folder: "website", started: "Wed Oct 29 10:41:27 2026")
    }

    public var tabs: [TerminalTab] { [guardedTab, waitingTab] }

    /// Both threads stopped on the usage limit earlier; the 5-hour window has reset since.
    public var sessions: [SessionState] {
        [
            session(Self.guardedThread, folder: "my-app", title: "Add dark mode", stoppedAgo: 3 * 3600 + 20 * 60),
            session(Self.waitingThread, folder: "website", title: "Update pricing page", stoppedAgo: 3 * 3600 + 5 * 60),
        ]
    }

    public var loadedThreadCwds: [String: String] {
        Dictionary(uniqueKeysWithValues: sessions.map { ($0.threadId, $0.cwd) })
    }

    /// Notice accepted, the longest countdown (so it is still running when the picture is taken),
    /// nothing that registers a login item.
    public var settings: Settings {
        var settings = Settings()
        settings.noticeAcceptedVersion = Notice.currentVersion
        settings.noticeAcceptedAt = now.addingTimeInterval(-14 * 86_400)
        settings.countdownSeconds = SettingsLimits.countdownSeconds.upperBound
        settings.launchAtLogin = false
        settings.autoSpendEnabled = true
        settings.autoSpendThreshold = 97
        return settings
    }

    // MARK: Files

    /// Earlier events, oldest first.
    public var activity: [ActivityEntry] {
        func entry(_ ago: TimeInterval, _ kind: ActivityKind, thread: String? = nil, tab: String? = nil,
                   text: String? = nil, detail: String? = nil) -> ActivityEntry {
            ActivityEntry(date: now.addingTimeInterval(-ago), kind: kind, threadId: thread, tab: tab, text: text,
                          detail: detail, codexVersion: Self.codexVersion)
        }
        return [
            entry(2 * 86_400 + 5 * 3600, .limitReached),
            entry(2 * 86_400 + 3 * 3600, .limitIsBack),
            entry(2 * 86_400 + 3 * 3600 - 10, .continueScheduled, thread: Self.guardedThread, tab: "/dev/ttys004",
                  text: "continue", detail: "countdown 10 s"),
            entry(2 * 86_400 + 3 * 3600 - 20, .continueSent, thread: Self.guardedThread, tab: "/dev/ttys004", text: "continue"),
            entry(86_400 + 2 * 3600, .resetExpiring, detail: "credit demo-credit-0 expires in 20 h"),
            entry(86_400, .resetUsed, detail: "outcome reset, credit demo-credit-0, manual"),
            entry(4 * 3600, .resetExpiring, detail: "credit demo-credit-1 expires in 24 h"),
            entry(3 * 3600 + 20 * 60, .limitReached),
        ]
    }

    /// 30 days of 5-hour and weekly readings, every 20 minutes, ending at the snapshot's values.
    public var history: [UsageSample] {
        let step: TimeInterval = 20 * 60
        let count = Int(UsageHistory.retention / step) - 1
        let fiveStart = fiveHourResetsAt.addingTimeInterval(-5 * 3600)
        let weekStart = weeklyResetsAt.addingTimeInterval(-7 * 86_400)
        return (0...count).reversed().map { index in
            let date = now.addingTimeInterval(-Double(index) * step)
            return UsageSample(
                date: date,
                fiveHour: Self.used(
                    at: date, windowStart: fiveStart, length: 5 * 3600, current: 42, now: now, peaks: 25...90, idleShare: 0.45),
                weekly: Self.used(at: date, windowStart: weekStart, length: 7 * 86_400, current: 63, now: now, peaks: 70...96))
        }
    }

    /// The my-app tab guarded; both stops and the soon-expiring credit already noted (in `activity`),
    /// so the Engine's first tick only adds the countdown.
    public var state: AppState {
        var state = AppState()
        state.guardedTabs = [GuardedTab(ref: guardedTab.ref, addedAt: now.addingTimeInterval(-5 * 3600))]
        for session in sessions {
            guard case let .usageLimit(at, turnId) = session.lastStop else { continue }
            state.stops[session.threadId] = StopInfo(turnId: turnId, isWeekly: false, resetsAt: at.addingTimeInterval(30 * 60))
        }
        state.expiryNotified = ["demo-credit-1"]
        return state
    }

    /// Writes `settings.json`, `state.json`, `activity.json` and `usage-history.json` into `directory`.
    @MainActor
    public func seed(into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONStore<Settings>(url: directory.appending(path: "settings.json"), schemaVersion: 1).save(settings)
        try JSONStore<AppState>(url: directory.appending(path: Engine.stateFileName), schemaVersion: 1).save(state)
        let activityLog = ActivityLog(url: directory.appending(path: Engine.activityFileName))
        for entry in activity { try activityLog.append(entry) }
        try JSONStore<UsageHistoryFile>(url: directory.appending(path: Engine.usageHistoryFileName), schemaVersion: 1)
            .save(UsageHistoryFile(samples: history))
    }

    // MARK: Helpers

    private func credit(id: String, grantedDaysAgo: Double, expiresIn: TimeInterval) -> [String: Any] {
        [
            "id": id, "status": "available", "title": Self.creditTitle,
            "grantedAt": seconds(now.addingTimeInterval(-grantedDaysAgo * 86_400)),
            "expiresAt": seconds(now.addingTimeInterval(expiresIn)),
        ]
    }

    private func tab(window: Int, tty: String, pid: Int32, folder: String, started: String) -> TerminalTab {
        TerminalTab(
            ref: TabRef(windowId: window, tabIndex: 1, tty: tty, pid: pid, startTime: started),
            title: folder, cwd: "\(home)/Projects/\(folder)", codexPid: pid, busy: false)
    }

    private func session(_ id: String, folder: String, title: String, stoppedAgo: TimeInterval) -> SessionState {
        let stoppedAt = now.addingTimeInterval(-stoppedAgo)
        var state = SessionState(
            threadId: id, cwd: "\(home)/Projects/\(folder)", originator: TabMatcher.tuiOriginator,
            lastStop: .usageLimit(at: stoppedAt, turnId: "\(id)-turn-7"), userActivityAfterStop: false,
            lastActivityAt: stoppedAt, lastTurnDurations: [540, 1260, 880],
            languageSample: "Please run the tests in this project and fix the failing ones.",
            seenClientMessageIds: [])
        state.title = title
        return state
    }

    private func seconds(_ date: Date) -> Int { Int(date.timeIntervalSince1970) }

    private func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// A repeatable value in 0…1 for `index`.
    static func noise(_ index: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: index &* 2_654_435_761 &+ 97)
        x ^= x >> 13
        x = x &* 0x5bd1_e995
        x ^= x >> 15
        return Double(x % 1000) / 999
    }

    /// Percent used at `date` in a window of `length` that repeats back from `windowStart`: rises from
    /// 0 to a peak per window (`idleShare` of the earlier windows stay almost unused); the current
    /// window rises to `current` at `now`.
    static func used(at date: Date, windowStart: Date, length: TimeInterval, current: Double, now: Date,
                     peaks: ClosedRange<Double>, idleShare: Double = 0) -> Double {
        let offset = date.timeIntervalSince(windowStart)
        let window = Int((offset / length).rounded(.down))
        let start = windowStart.addingTimeInterval(Double(window) * length)
        let elapsed = date.timeIntervalSince(start)
        if window >= 0 {
            let soFar = max(now.timeIntervalSince(start), 1)
            return (current * min(elapsed / soFar, 1) * 10).rounded() / 10
        }
        let idle = noise(window + 2000) < idleShare
        let peak = idle ? 3 * noise(window + 3000) : peaks.lowerBound + (peaks.upperBound - peaks.lowerBound) * noise(window + 1000)
        return (peak * elapsed / length * 10).rounded() / 10
    }
}

/// `codex app-server` for the screenshots: answers the two reads from the fixture and nothing else.
/// Every other method (above all `account/rateLimitResetCredit/consume`) gets an error.
public final class ScreenshotAppServer: AppServerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let replies: [String: String]
    private var _onLine: (@Sendable (Data) -> Void)?
    private var _onExit: (@Sendable (Int32) -> Void)?

    public init(fixture: ScreenshotFixture) {
        replies = [
            "initialize": "{}",
            "account/rateLimits/read": fixture.limitsResult,
            "account/usage/read": fixture.usageResult,
        ]
    }

    public var onLine: (@Sendable (Data) -> Void)? {
        get { lock.withLock { _onLine } }
        set { lock.withLock { _onLine = newValue } }
    }

    public var onExit: (@Sendable (Int32) -> Void)? {
        get { lock.withLock { _onExit } }
        set { lock.withLock { _onExit = newValue } }
    }

    public func start() throws {}
    public func stop() {}

    public func send(_ line: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let method = object["method"] as? String, let id = object["id"] as? Int else { return }
        let payload = replies[method].map { #"{"id":\#(id),"result":\#($0)}"# }
            ?? #"{"id":\#(id),"error":{"code":-32601,"message":"not available in screenshot mode"}}"#
        let onLine = self.onLine
        DispatchQueue.global().async { onLine?(Data(payload.utf8)) }
    }
}

/// The fixture's tabs, with no notifications and no keep-awake.
public struct ScreenshotEnvironment: EngineEnvironment {
    let fixture: ScreenshotFixture
    public init(fixture: ScreenshotFixture) { self.fixture = fixture }
    public func terminalTabs() async -> [TerminalTab]? { fixture.tabs }
    public func notify(_ note: EngineNote) async {}
    public func setKeepAwake(_ on: Bool) async {}
}

public struct ScreenshotSessions: SessionSource {
    let fixture: ScreenshotFixture
    public init(fixture: ScreenshotFixture) { self.fixture = fixture }
    public func scan(now: Date) async -> [SessionState] { fixture.sessions }
}

/// Maps the fixture's threads to their folders; a delivery is never sent anywhere.
public struct ScreenshotDelivery: EngineDelivery {
    let fixture: ScreenshotFixture
    public init(fixture: ScreenshotFixture) { self.fixture = fixture }
    public func loadedThreadCwds() async throws -> [String: String] { fixture.loadedThreadCwds }
    public func deliver(_ request: ContinueRequest) async -> DeliveryResult { .sent }
}
#endif
