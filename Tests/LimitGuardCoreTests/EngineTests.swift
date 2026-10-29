import Foundation
import Testing
@testable import LimitGuardCore

// MARK: - Test doubles

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
private let turkishSample = "Lütfen bu projedeki testleri çalıştır ve başarısız olanları düzelt, sonra bana kısa bir özet ver."
private let tty1 = "/dev/ttys001"
private let tty2 = "/dev/ttys002"
private let consumeMethod = "account/rateLimitResetCredit/consume"
private let limitsMethod = "account/rateLimits/read"

/// Manual time: tests drive the Engine through `tick()` and move the clock themselves.
final class TestClock: EngineClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    init(_ now: Date) { _now = now }

    var now: Date { lock.withLock { _now } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { _now = _now.addingTimeInterval(seconds) }
    }

    func sleep(until date: Date) async throws {
        while now < date { try await Task.sleep(for: .milliseconds(5)) }
    }
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

private final class FakeSessions: SessionSource, @unchecked Sendable {
    let current = Box<[SessionState]>([])
    func scan(now: Date) async -> [SessionState] { current.value }
}

private final class FakeEnvironment: EngineEnvironment, @unchecked Sendable {
    /// nil: the process listing fails.
    let tabs = Box<[TerminalTab]?>([])
    let notes = Box<[EngineNote]>([])
    let keepAwake = Box<[Bool]>([])

    func terminalTabs() async -> [TerminalTab]? { tabs.value }
    func notify(_ note: EngineNote) async { notes.value.append(note) }
    func setKeepAwake(_ on: Bool) async { keepAwake.value.append(on) }
}

/// A delivery whose `deliver` waits until `release()`, to hold a send in flight.
private final class SuspendingDelivery: EngineDelivery, @unchecked Sendable {
    let cwds: [String: String]
    let requests = Box<[ContinueRequest]>([])
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(cwds: [String: String]) { self.cwds = cwds }

    func loadedThreadCwds() async throws -> [String: String] { cwds }

    func deliver(_ request: ContinueRequest) async -> DeliveryResult {
        requests.value.append(request)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go = lock.withLock { () -> Bool in
                if released { return true }
                waiting.append(continuation)
                return false
            }
            if go { continuation.resume() }
        }
        return .sent
    }

    func release() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { waiting = [] }
            return waiting
        }
        all.forEach { $0.resume() }
    }
}

/// Polls until `condition` holds (at most about 2 s).
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<2000 where !condition() { try await Task.sleep(for: .milliseconds(1)) }
    #expect(condition())
}

private func acceptedSettings(_ change: (inout Settings) -> Void = { _ in }) -> Settings {
    var settings = Settings()
    settings.noticeAcceptedVersion = Notice.currentVersion
    settings.noticeAcceptedAt = t0
    change(&settings)
    return settings
}

private func limitsJSON(
    allowed: Bool?, five: Double = 100, fiveResets: Date? = t0.addingTimeInterval(3600),
    weekly: Double = 50, weeklyResets: Date? = t0.addingTimeInterval(5 * 86_400),
    accountId: String = "acct-1", reached: String? = nil, credits: [(String, Date?)] = []
) -> String {
    var root: [String: Any] = ["accountId": accountId]
    if let allowed { root["ordinaryUsageAllowed"] = allowed }
    var primary: [String: Any] = ["usedPercent": five, "windowDurationMins": 300]
    if let fiveResets { primary["resetsAt"] = Int(fiveResets.timeIntervalSince1970) }
    var secondary: [String: Any] = ["usedPercent": weekly, "windowDurationMins": 10_080]
    if let weeklyResets { secondary["resetsAt"] = Int(weeklyResets.timeIntervalSince1970) }
    var limits: [String: Any] = ["primary": primary, "secondary": secondary, "planType": "plus"]
    if let reached { limits["rateLimitReachedType"] = reached }
    root["rateLimits"] = limits
    root["rateLimitResetCredits"] = [
        "availableCount": credits.count,
        "credits": credits.map { id, expires -> [String: Any] in
            var credit: [String: Any] = ["id": id, "status": "available", "grantedAt": Int(t0.timeIntervalSince1970) - 86_400]
            if let expires { credit["expiresAt"] = Int(expires.timeIntervalSince1970) }
            return credit
        },
    ]
    let data = try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func waiting(
    _ id: String = "th1", at: Date = t0, turn: String = "turn-1", cwd: String = "/p",
    durations: [TimeInterval] = [], activity: Bool = false, seen: Set<String> = []
) -> SessionState {
    SessionState(
        threadId: id, cwd: cwd, originator: "codex-tui", lastStop: .usageLimit(at: at, turnId: turn),
        userActivityAfterStop: activity, lastActivityAt: at, lastTurnDurations: durations,
        languageSample: turkishSample, seenClientMessageIds: seen)
}

private func finished(_ id: String = "th1", at: Date) -> SessionState {
    SessionState(
        threadId: id, cwd: "/p", originator: "codex-tui", lastStop: .none, userActivityAfterStop: false,
        lastActivityAt: at, lastTurnDurations: [300], languageSample: turkishSample, seenClientMessageIds: [])
}

private func tab(_ tty: String = tty1, cwd: String? = "/p", pid: Int32 = 100, started: String? = nil) -> TerminalTab {
    TerminalTab(ref: ref(tty, pid: pid, started: started), title: "p", cwd: cwd, codexPid: pid, busy: false)
}

/// The tab's identity: tty, Codex pid and that process's start time.
private func ref(_ tty: String = tty1, pid: Int32 = 100, started: String? = nil) -> TabRef {
    TabRef(windowId: 0, tabIndex: 0, tty: tty, pid: pid, startTime: started ?? "start-\(pid)")
}

/// One Engine with fakes for codex (reads + consume), the shared daemon (delivery), the sessions
/// and the system, over a temporary data directory.
@MainActor
private final class Harness {
    let dir: TemporaryDirectory
    let clock = TestClock(t0)
    let account = FakeAppServer()
    let daemon = FakeAppServer()
    let sessions = FakeSessions()
    let env = FakeEnvironment()
    let settings: Box<Settings>
    let engine: Engine

    init(settings: Settings = acceptedSettings(), delivery: EngineDelivery? = nil, prepare: (URL) throws -> Void = { _ in }) throws {
        dir = try TemporaryDirectory()
        try prepare(dir.url)
        self.settings = Box(settings)
        let clock = clock
        let account = account
        let daemon = daemon
        let service = CodexAccountService(
            client: AppServerClient(transportFactory: { account }, clientName: "test", clientVersion: "0", backoff: [.zero]),
            now: { clock.now })
        let delivery = delivery ?? AppServerDelivery(
            client: AppServerClient(transportFactory: { daemon }, clientName: "test", clientVersion: "0", backoff: [.zero]))
        let box = self.settings
        engine = Engine(Engine.Dependencies(
            clock: clock, environment: env, account: service, sessions: sessions, delivery: delivery,
            dataDirectory: dir.url, settings: { box.value }, codexVersion: "codex-cli 0.0.0-test",
            resetSleeper: { _ in }))
    }

    deinit { dir.remove() }

    func limits(_ json: String) { account.script(limitsMethod, result: json) }

    /// The daemon has `threads` loaded, all in `cwd`.
    func loaded(_ threads: [String], cwd: String = "/p") {
        let ids = threads.map { "\"\($0)\"" }.joined(separator: ",")
        daemon.script("thread/loaded/list", result: #"{"data":[\#(ids)],"nextCursor":null}"#)
        daemon.script("thread/read", result: #"{"thread":{"cwd":"\#(cwd)","status":{"type":"systemError"},"ephemeral":false}}"#)
        daemon.script("turn/start", result: #"{"turn":{"id":"t-new","status":"inProgress"}}"#)
    }

    func turnStarts() -> [[String: Any]] {
        daemon.sentLines.compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["method"] as? String == "turn/start" else { return nil }
            return object["params"] as? [String: Any]
        }
    }

    func sentText(_ params: [String: Any]) -> String? {
        ((params["input"] as? [[String: Any]])?.first)?["text"] as? String
    }

    func clientId(_ params: [String: Any]) -> String? { params["clientUserMessageId"] as? String }

    func consumes() -> [FakeAppServer.Request] { account.requests.filter { $0.method == consumeMethod } }

    func storedState() throws -> AppState {
        try #require(try JSONStore<AppState>(url: dir.url.appending(path: "state.json"), schemaVersion: 1).load())
    }

    func activity() throws -> [ActivityEntry] {
        try ActivityLog(url: dir.url.appending(path: "activity.json")).entries()
    }

    var notes: [EngineNote] { env.notes.value }

    func skips(_ thread: String = "th1") -> [String] {
        notes.compactMap { note in
            if case let .continueSkipped(id, reason) = note, id == thread { return reason }
            return nil
        }
    }

    /// Advances the clock in `step`s for `total` seconds, ticking after each step.
    func run(for total: TimeInterval, step: TimeInterval = 30) async {
        var elapsed: TimeInterval = 0
        while elapsed < total {
            clock.advance(by: step)
            elapsed += step
            await engine.tick()
        }
    }

    /// A guarded tab in /p running Codex for thread `th1`, which is waiting on a usage-limit stop.
    func standardWaitingSetup(guarded: Bool = true) {
        sessions.current.value = [waiting()]
        env.tabs.value = [tab()]
        loaded(["th1"])
        if guarded { engine.setGuarded(ref(), true) }
    }
}

// MARK: - Engine

@Suite("Engine")
@MainActor
struct EngineTests {
    /// The last limits read's failure is published by kind, so the popover can say "not signed in".
    @Test func readFailureIsPublishedByKind() async throws {
        let h = try Harness()
        h.account.scriptError(limitsMethod, code: -32600, message: "Unauthorized: please run codex login")
        await h.engine.tick()
        #expect(h.engine.readFailure == .notSignedIn)
        #expect(h.engine.readError != nil)

        h.limits(limitsJSON(allowed: true, five: 10))
        h.clock.advance(by: 600)
        await h.engine.tick()
        #expect(h.engine.readFailure == nil)
        #expect(h.engine.readError == nil)
    }

    @Test func happyPathContinues() async throws {
        let h = try Harness()
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: false, five: 100, fiveResets: t0.addingTimeInterval(3600)))
        await h.engine.tick()
        #expect(h.turnStarts().isEmpty)
        #expect(h.engine.nextAction == NextAction(kind: .continueAt(t0.addingTimeInterval(3600), threadId: "th1", text: "devam et")))

        h.clock.advance(by: 3600)
        h.limits(limitsJSON(allowed: true, five: 0, fiveResets: t0.addingTimeInterval(6 * 3600)))
        await h.engine.tick()
        #expect(h.turnStarts().isEmpty)
        #expect(h.notes.contains(.continueCountdown(threadId: "th1", seconds: 10)))
        #expect(h.engine.nextAction == NextAction(kind: .countdown(until: t0.addingTimeInterval(3610), threadId: "th1", text: "devam et")))

        h.clock.advance(by: 10)
        await h.engine.tick()
        let starts = h.turnStarts()
        #expect(starts.count == 1)
        #expect(starts.first.flatMap(h.sentText) == "devam et")
        #expect(starts.first?["threadId"] as? String == "th1")
        #expect(h.notes.contains(.continueSent(threadId: "th1")))
        let pending = try h.storedState().pendingDeliveries
        #expect(pending.count == 1)
        #expect(pending.first?.clientMessageId.uuidString.lowercased() == starts.first.flatMap(h.clientId))
        #expect(try h.activity().contains { $0.kind == .continueSent && $0.text == "devam et" && $0.tab == tty1 })
    }

    @Test func recheckBeforeSendAborts() async throws {
        let h = try Harness()
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.engine.tick()
        #expect(h.notes.contains(.continueCountdown(threadId: "th1", seconds: 10)))

        h.sessions.current.value = [waiting(activity: true)]
        h.clock.advance(by: 10)
        await h.engine.tick()
        await h.run(for: 300)
        #expect(h.turnStarts().isEmpty)
        #expect(h.skips().count == 1)
    }

    @Test func cancelDuringCountdown() async throws {
        let h = try Harness()
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.engine.tick()
        #expect(h.engine.nextAction != nil)

        h.engine.cancelNextAction()
        #expect(h.engine.nextAction == nil)
        await h.run(for: 900)
        #expect(h.turnStarts().isEmpty)
        #expect(try h.activity().contains { $0.kind == .continueCancelled && $0.threadId == "th1" })
    }

    @Test func unconfirmedIsNeverResent() async throws {
        let h = try Harness()
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.engine.tick()
        h.clock.advance(by: 10)
        await h.engine.tick()
        #expect(h.turnStarts().count == 1)

        await h.run(for: 150)
        #expect(h.notes.filter { $0 == .unconfirmed(threadId: "th1") }.count == 1)
        await h.run(for: 600)
        #expect(h.turnStarts().count == 1)
        #expect(h.notes.filter { $0 == .unconfirmed(threadId: "th1") }.count == 1)
        #expect(try h.activity().contains { $0.kind == .unconfirmed })
    }

    @Test func wakeRunsMissedContinueOnce() async throws {
        let h = try Harness()
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: false, five: 100, fiveResets: t0.addingTimeInterval(3600)))
        await h.engine.tick()

        // The Mac slept through the reset.
        h.clock.advance(by: 3 * 3600)
        h.limits(limitsJSON(allowed: true, five: 0, fiveResets: t0.addingTimeInterval(8 * 3600)))
        await h.engine.tick()
        #expect(h.turnStarts().isEmpty)
        h.clock.advance(by: 10)
        await h.engine.tick()
        await h.run(for: 600)
        #expect(h.turnStarts().count == 1)
    }

    @Test func autoSpendThenContinue() async throws {
        let h = try Harness(settings: acceptedSettings { $0.autoSpendEnabled = true })
        h.standardWaitingSetup()
        let weeklyResets = t0.addingTimeInterval(3 * 86_400)
        let credits: [(String, Date?)] = [("c-late", t0.addingTimeInterval(10 * 86_400)), ("c-early", t0.addingTimeInterval(2 * 86_400))]
        h.account.scriptQueue(limitsMethod, [.result(limitsJSON(
            allowed: false, five: 40, weekly: 97, weeklyResets: weeklyResets, reached: "weekly", credits: credits))])
        h.limits(limitsJSON(allowed: true, five: 0, weekly: 0, weeklyResets: weeklyResets, credits: [("c-late", t0.addingTimeInterval(10 * 86_400))]))
        h.account.script(consumeMethod, result: #"{"outcome":"reset"}"#)

        await h.engine.tick()
        let consumes = h.consumes()
        #expect(consumes.count == 1)
        #expect(consumes.first?.params["creditId"] == "c-early")
        let methods = h.account.requests.map(\.method)
        let consumeIndex = try #require(methods.firstIndex(of: consumeMethod))
        #expect(methods[(consumeIndex + 1)...].contains(limitsMethod))
        #expect(h.notes.contains(.resetUsed(.reset)))
        #expect(try h.storedState().stops["th1"]?.isWeekly == true)

        h.clock.advance(by: 10)
        await h.engine.tick()
        await h.run(for: 300)
        #expect(h.turnStarts().count == 1)
        #expect(h.consumes().count == 1)
    }

    @Test func markerWrittenBeforeAutoSpend() async throws {
        let h = try Harness(settings: acceptedSettings { $0.autoSpendEnabled = true })
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: false, five: 40, weekly: 98, reached: "weekly", credits: [("c1", nil)]))
        h.account.script(consumeMethod, result: #"{"outcome":"nothingToReset"}"#)
        let stateURL = h.dir.url.appending(path: "state.json")
        let seen = Box<AutoSpendMarker?>(nil)
        h.account.onRequest = { request in
            if request.method == consumeMethod {
                seen.value = (try? JSONStore<AppState>(url: stateURL, schemaVersion: 1).load())?.autoSpend
            }
        }
        await h.engine.tick()
        #expect(h.consumes().count == 1)
        #expect(seen.value == AutoSpendMarker(accountId: "acct-1", spentAt: t0))
        // Kept whatever the outcome.
        #expect(try h.storedState().autoSpend == AutoSpendMarker(accountId: "acct-1", spentAt: t0))
        #expect(h.notes.contains(.resetUsed(.nothingToReset)))
    }

    @Test func unknownSpendDisablesAutoSpend() async throws {
        let h = try Harness(settings: acceptedSettings { $0.autoSpendEnabled = true })
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: false, five: 40, weekly: 98, accountId: "acct-1", reached: "weekly", credits: [("c1", nil)]))
        h.account.scriptError(consumeMethod, code: -32000, message: "boom")
        await h.engine.tick()
        #expect(h.consumes().count == 1)
        #expect(h.notes.contains { if case .readOnly = $0 { return true } else { return false } })

        // Another account would be allowed by the one-per-week marker; the unknown result blocks it.
        h.limits(limitsJSON(allowed: false, five: 40, weekly: 98, accountId: "acct-2", reached: "weekly", credits: [("c2", nil)]))
        await h.run(for: 900, step: 60)
        #expect(h.consumes().count == 1)
    }

    @Test func resumePendingAtLaunchUsesStoredKey() async throws {
        let key = UUID()
        let h = try Harness { dir in
            let store = JSONStore<LedgerFile>(url: dir.appending(path: "reset-ledger.json"), schemaVersion: 1)
            try store.save(LedgerFile(entries: [LedgerEntry(
                idempotencyKey: key, creditId: "c-stored", reason: .manual, createdAt: t0.addingTimeInterval(-600), attempts: 1)]))
        }
        h.limits(limitsJSON(allowed: false))
        h.account.script(consumeMethod, result: #"{"outcome":"reset"}"#)
        await h.engine.tick()
        let consumes = h.consumes()
        #expect(consumes.count == 1)
        #expect(consumes.first?.params["idempotencyKey"] == key.uuidString.lowercased())
        #expect(consumes.first?.params["creditId"] == "c-stored")
        #expect(h.notes.contains(.resetUsed(.reset)))
        let ledger = try JSONStore<LedgerFile>(url: h.dir.url.appending(path: "reset-ledger.json"), schemaVersion: 1).load()
        #expect(ledger?.entries.isEmpty == true)
    }

    @Test func expiredLedgerEntryIsNotedNotSent() async throws {
        let h = try Harness { dir in
            let store = JSONStore<LedgerFile>(url: dir.appending(path: "reset-ledger.json"), schemaVersion: 1)
            try store.save(LedgerFile(entries: [LedgerEntry(
                idempotencyKey: UUID(), creditId: "c-old", reason: .auto, createdAt: t0.addingTimeInterval(-25 * 3600), attempts: 4)]))
        }
        h.limits(limitsJSON(allowed: false))
        await h.engine.tick()
        #expect(h.consumes().isEmpty)
        #expect(h.notes.contains(.resetResultUnknown(creditId: "c-old")))
    }

    @Test func limitIsBackNotifiesOnce() async throws {
        let h = try Harness()
        h.limits(limitsJSON(allowed: false))
        await h.engine.tick()
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.run(for: 1800, step: 60)
        #expect(h.notes.filter { $0 == .limitIsBack }.count == 1)
    }

    @Test func noticeNotAcceptedDoesNothing() async throws {
        let h = try Harness(settings: { var s = Settings(); s.autoSpendEnabled = true; return s }())
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: true, five: 0, weekly: 99, credits: [("c1", nil)]))
        h.account.script(consumeMethod, result: #"{"outcome":"reset"}"#)
        await h.engine.tick()
        await h.run(for: 600)
        #expect(h.turnStarts().isEmpty)
        #expect(h.consumes().isEmpty)
        #expect(h.engine.snapshot?.ordinaryUsageAllowed == true)
    }

    @Test func keepAwakeOnlyWhileWaiting() async throws {
        let h = try Harness()
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: false, five: 100, fiveResets: t0.addingTimeInterval(3600)))
        await h.engine.tick()
        #expect(h.env.keepAwake.value == [true])

        h.clock.advance(by: 3600)
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.engine.tick()
        h.clock.advance(by: 10)
        await h.engine.tick()
        #expect(h.turnStarts().count == 1)
        #expect(h.env.keepAwake.value == [true, false])
    }

    @Test func keepAwakeNotForLongWaits() async throws {
        let h = try Harness()
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: false, five: 100, fiveResets: t0.addingTimeInterval(7 * 3600)))
        await h.engine.tick()
        #expect(h.env.keepAwake.value.isEmpty)
    }

    @Test func stopInfoRecordedOnFirstSightAndCleared() async throws {
        let h = try Harness()
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: false, five: 100, fiveResets: t0.addingTimeInterval(3600)))
        await h.engine.tick()
        let recorded = StopInfo(turnId: "turn-1", isWeekly: false, resetsAt: t0.addingTimeInterval(3600))
        #expect(try h.storedState().stops["th1"] == recorded)

        // The live window moves on; the recorded classification stays.
        h.limits(limitsJSON(allowed: false, five: 100, fiveResets: t0.addingTimeInterval(9000), weekly: 100))
        h.clock.advance(by: 60)
        await h.engine.tick()
        #expect(try h.storedState().stops["th1"] == recorded)

        h.sessions.current.value = [finished(at: t0.addingTimeInterval(120))]
        h.clock.advance(by: 60)
        await h.engine.tick()
        #expect(try h.storedState().stops["th1"] == nil)
    }

    @Test func unguardedTabIsNotContinued() async throws {
        let h = try Harness()
        h.standardWaitingSetup(guarded: false)
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.engine.tick()
        await h.run(for: 600)
        #expect(h.turnStarts().isEmpty)
        #expect(h.engine.tabs.count == 1)
        #expect(h.engine.tabs.first?.isGuarded == false)
        #expect(h.engine.tabs.first?.threadId == "th1")
        #expect(h.engine.tabs.first?.isWaiting == true)
        #expect(h.env.keepAwake.value.isEmpty)
    }

    @Test func ambiguousTabsAreNotContinued() async throws {
        let h = try Harness()
        h.sessions.current.value = [waiting("th1"), waiting("th2", turn: "turn-2")]
        h.env.tabs.value = [tab(tty1, pid: 100), tab(tty2, pid: 200)]
        h.loaded(["th1", "th2"])
        h.engine.setGuarded(ref(tty1), true)
        h.engine.setGuarded(ref(tty2, pid: 200), true)
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.engine.tick()
        await h.run(for: 600)
        #expect(h.turnStarts().isEmpty)
        #expect(h.skips("th1").count == 1)
        #expect(h.skips("th2").count == 1)
    }

    /// The empty thread a TUI opens at start stays loaded after `/resume`; the scanner does not know it,
    /// so the tab pairs with the real session, and the popover shows the same pairing.
    @Test func unknownLoadedThreadDoesNotMakeTheTabAmbiguous() async throws {
        let h = try Harness()
        h.sessions.current.value = [waiting("th1")]
        h.env.tabs.value = [tab()]
        h.loaded(["th1", "empty-thread"])
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.engine.tick()
        #expect(h.engine.tabs.first?.threadId == "th1")
        let rows = SessionsPresentation.rows(
            tabs: h.engine.tabs, sessions: h.engine.sessions, snapshot: h.engine.snapshot, now: h.clock.now)
        #expect(rows.map(\.state) == [.waitingNotGuarded])
        #expect(rows.first?.threadId == "th1")
    }

    /// Two real sessions in the tab's folder stay ambiguous (D18), in the Engine and in the popover.
    @Test func twoKnownThreadsInOneFolderStayAmbiguous() async throws {
        let h = try Harness()
        h.sessions.current.value = [waiting("th1"), finished("th2", at: t0)]
        h.env.tabs.value = [tab()]
        h.loaded(["th1", "th2", "empty-thread"])
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.engine.tick()
        #expect(h.engine.tabs.first?.threadId == nil)
        let rows = SessionsPresentation.rows(
            tabs: h.engine.tabs, sessions: h.engine.sessions, snapshot: h.engine.snapshot, now: h.clock.now)
        #expect(rows.map(\.state) == [.ambiguous])
    }

    @Test func daemonUnreachableSkipsWithNote() async throws {
        let h = try Harness()
        h.sessions.current.value = [waiting()]
        h.env.tabs.value = [tab()]
        h.engine.setGuarded(ref(), true)
        h.daemon.scriptError("thread/loaded/list", code: -32000, message: "no daemon")
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.engine.tick()
        await h.run(for: 600)
        #expect(h.turnStarts().isEmpty)
        #expect(h.skips() == ["Codex daemon not reachable"])
    }

    @Test func daemonDownAtSendTimeSkipsWithNote() async throws {
        let h = try Harness()
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.engine.tick()
        #expect(h.notes.contains(.continueCountdown(threadId: "th1", seconds: 10)))
        h.daemon.scriptError("thread/loaded/list", code: -32000, message: "no daemon")
        h.clock.advance(by: 10)
        await h.engine.tick()
        await h.run(for: 300)
        #expect(h.turnStarts().isEmpty)
        #expect(h.skips() == ["Codex daemon not reachable"])
    }

    /// Lets the current stop of `th1` be continued (countdown 0) and confirms the continue in the rollout.
    private func continueAndConfirm(_ h: Harness, turn: String, duration: TimeInterval) async throws {
        h.clock.advance(by: 130)
        let before = h.turnStarts().count
        h.sessions.current.value = [waiting(at: h.clock.now, turn: turn, durations: [duration])]
        await h.engine.tick()
        let starts = h.turnStarts()
        guard starts.count == before + 1 else { return }
        let id = try #require(starts.last.flatMap(h.clientId))
        h.clock.advance(by: 5)
        h.sessions.current.value = [waiting(at: h.clock.now - 5, turn: turn, durations: [duration], activity: true, seen: [id])]
        await h.engine.tick()
        #expect(try h.storedState().pendingDeliveries.isEmpty)
    }

    @Test func loopGuardStopsAfterThree() async throws {
        let h = try Harness(settings: acceptedSettings { $0.countdownSeconds = 0 })
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: true, five: 0))
        for turn in 1...3 {
            try await continueAndConfirm(h, turn: "turn-\(turn)", duration: 300)
            #expect(h.turnStarts().count == turn)
        }
        #expect(try h.storedState().loop["th1"]?.consecutive == 3)
        try await continueAndConfirm(h, turn: "turn-4", duration: 300)
        await h.run(for: 600)
        #expect(h.turnStarts().count == 3)
        #expect(h.notes.filter { $0 == .loopStopped(threadId: "th1") }.count == 1)
    }

    @Test func ownerTypingResetsTheLoopCounter() async throws {
        let h = try Harness(settings: acceptedSettings { $0.countdownSeconds = 0 })
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: true, five: 0))
        try await continueAndConfirm(h, turn: "turn-1", duration: 300)
        try await continueAndConfirm(h, turn: "turn-2", duration: 300)
        #expect(try h.storedState().loop["th1"]?.consecutive == 2)
        // A new stop inside the minimum gap (so nothing is sent yet), then the owner types.
        h.clock.advance(by: 10)
        let stopAt = h.clock.now
        h.sessions.current.value = [waiting(at: stopAt, turn: "turn-3", durations: [300])]
        await h.engine.tick()
        #expect(h.turnStarts().count == 2)
        #expect(try h.storedState().stops["th1"]?.turnId == "turn-3")
        h.clock.advance(by: 10)
        h.sessions.current.value = [waiting(at: stopAt, turn: "turn-3", durations: [300], activity: true)]
        await h.engine.tick()
        #expect(try h.storedState().loop["th1"]?.consecutive == 0)
        #expect(try h.storedState().stops["th1"] == nil)
    }

    @Test func runawayBrakeStops() async throws {
        let h = try Harness(settings: acceptedSettings { $0.countdownSeconds = 0; $0.maxContinues = 10 })
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: true, five: 0))
        for turn in 1...3 {
            try await continueAndConfirm(h, turn: "turn-\(turn)", duration: 5)
        }
        try await continueAndConfirm(h, turn: "turn-4", duration: 5)
        await h.run(for: 600)
        #expect(h.turnStarts().count == 3)
        #expect(try h.storedState().loop["th1"]?.shortTurnsInARow == 3)
        #expect(h.notes.contains(.runawayStopped(threadId: "th1")))
    }

    @Test func unclassifiableStopKeepsTheCadence() async throws {
        let h = try Harness()
        h.standardWaitingSetup()
        // No `ordinaryUsageAllowed`: read-only, so the stop can never be classified.
        h.limits(limitsJSON(allowed: nil, five: 10, weekly: 10))
        await h.engine.tick()
        await h.run(for: 600)
        let reads = h.account.requests.filter { $0.method == limitsMethod }.count
        // Every 5 min plus the one extra read for the new stop; never one per 30 s tick.
        #expect(reads <= 4)
        #expect(h.turnStarts().isEmpty)
    }

    @Test func sendsAreSerialised() async throws {
        let delivery = SuspendingDelivery(cwds: ["th1": "/p"])
        let h = try Harness(settings: acceptedSettings { $0.countdownSeconds = 0 }, delivery: delivery)
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: true, five: 0))
        let first = Task { await h.engine.tick() }
        try await waitUntil { delivery.requests.value.count == 1 }

        let secondDone = Box(false)
        let second = Task { await h.engine.tick(); secondDone.value = true }
        let third = Task { await h.engine.tick() }
        let manual = Task { await h.engine.continueNow(threadId: "th1") }
        try await Task.sleep(for: .milliseconds(50))
        // Nothing else runs while the first send is in flight.
        #expect(secondDone.value == false)
        delivery.release()
        _ = await (first.value, second.value, third.value, manual.value)
        #expect(secondDone.value)
        #expect(delivery.requests.value.count == 1)
    }

    @Test func cancelDuringSendIsTooLate() async throws {
        let delivery = SuspendingDelivery(cwds: ["th1": "/p"])
        let h = try Harness(delivery: delivery)
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.engine.tick()
        #expect(h.engine.nextAction != nil)
        h.clock.advance(by: 10)
        let firing = Task { await h.engine.tick() }
        try await waitUntil { delivery.requests.value.count == 1 }
        #expect(h.engine.nextAction == nil)
        h.engine.cancelNextAction()
        delivery.release()
        await firing.value
        #expect(delivery.requests.value.count == 1)
        #expect(h.notes.contains(.continueSent(threadId: "th1")))
        let cancels = try h.activity().filter { $0.kind == .continueCancelled }
        #expect(cancels.count == 1)
        #expect(cancels.first?.detail == "Too late to cancel: the continue was already sent.")
    }

    @Test func cancelBetweenFireAndSendSendsNothing() async throws {
        let h = try Harness()
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.engine.tick()
        // Cancel while the firing tick waits on the limits read.
        h.account.script(limitsMethod, result: limitsJSON(allowed: true, five: 0), delay: .milliseconds(100))
        h.clock.advance(by: 10)
        let firing = Task { await h.engine.tick() }
        try await Task.sleep(for: .milliseconds(30))
        h.engine.cancelNextAction()
        await firing.value
        await h.run(for: 300)
        #expect(h.turnStarts().isEmpty)
    }

    /// Each continue is followed by owner-looking activity without our client id, then a new stop.
    private func runUnconfirmedCycles(_ h: Harness, stops: Int, duration: TimeInterval) async {
        for turn in 1...stops {
            h.clock.advance(by: 130)
            let stopAt = h.clock.now
            h.sessions.current.value = [waiting(at: stopAt, turn: "turn-\(turn)", durations: [duration])]
            let before = h.turnStarts().count
            await h.engine.tick()
            // Only our own continue starts a turn; a stop we did not continue stays as it is.
            guard h.turnStarts().count > before else {
                await h.run(for: 150)
                continue
            }
            h.clock.advance(by: 5)
            h.sessions.current.value = [waiting(at: stopAt, turn: "turn-\(turn)", durations: [duration], activity: true)]
            await h.run(for: 150)
        }
    }

    @Test func loopGuardHoldsWithoutConfirmation() async throws {
        let h = try Harness(settings: acceptedSettings { $0.countdownSeconds = 0 })
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: true, five: 0))
        await runUnconfirmedCycles(h, stops: 4, duration: 300)
        await h.run(for: 600)
        #expect(h.turnStarts().count == 3)
        #expect(h.notes.filter { $0 == .loopStopped(threadId: "th1") }.count == 1)
    }

    @Test func runawayBrakeHoldsWithoutConfirmation() async throws {
        let h = try Harness(settings: acceptedSettings { $0.countdownSeconds = 0; $0.maxContinues = 10 })
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: true, five: 0))
        await runUnconfirmedCycles(h, stops: 4, duration: 5)
        #expect(h.turnStarts().count == 3)
        #expect(h.notes.filter { $0 == .runawayStopped(threadId: "th1") }.count == 1)
    }

    @Test func psFailureKeepsGuardedTabs() async throws {
        let h = try Harness()
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: false))
        await h.engine.tick()
        h.env.tabs.value = nil
        await h.run(for: 120)
        #expect(try h.storedState().guardedTabs.map(\.ref) == [ref()])
        #expect(h.engine.tabs.map(\.tab.ref) == [ref()])
        h.env.tabs.value = [tab()]
        await h.run(for: 30)
        #expect(try h.storedState().guardedTabs.map(\.ref) == [ref()])
    }

    @Test func untickSticksWithAutoGuard() async throws {
        let h = try Harness(settings: acceptedSettings { $0.guardNewTabsAutomatically = true })
        h.standardWaitingSetup(guarded: false)
        h.limits(limitsJSON(allowed: false))
        await h.engine.tick()
        #expect(try h.storedState().guardedTabs.map(\.ref) == [ref()])
        h.engine.setGuarded(ref(), false)
        #expect(try h.storedState().untickedTabs == [ref()])
        h.env.tabs.value = nil
        await h.run(for: 60)
        h.env.tabs.value = [tab()]
        await h.run(for: 60)
        #expect(try h.storedState().guardedTabs.isEmpty)
        // Once the tab is gone the untick is forgotten; a new tab on that tty is guarded automatically.
        h.env.tabs.value = []
        await h.run(for: 30)
        #expect(try h.storedState().untickedTabs.isEmpty)
        h.env.tabs.value = [tab(pid: 300)]
        await h.run(for: 30)
        #expect(try h.storedState().guardedTabs.map(\.ref) == [ref(pid: 300)])
    }

    @Test func expiryReminderOncePerCredit() async throws {
        let h = try Harness()
        h.limits(limitsJSON(allowed: true, five: 0, credits: [("c-soon", t0.addingTimeInterval(10 * 3600)), ("c-later", t0.addingTimeInterval(5 * 86_400))]))
        await h.engine.tick()
        await h.run(for: 1800, step: 300)
        let reminders = h.notes.filter { if case .resetExpiring = $0 { return true } else { return false } }
        #expect(reminders == [.resetExpiring(creditId: "c-soon", at: t0.addingTimeInterval(10 * 3600))])
        #expect(try h.storedState().expiryNotified == ["c-soon"])
    }

    @Test func continueNowBypassesCountdownButNotGate() async throws {
        let h = try Harness()
        h.standardWaitingSetup(guarded: false)
        h.limits(limitsJSON(allowed: false))
        await h.engine.tick()
        await h.engine.continueNow(threadId: "th1")
        #expect(h.turnStarts().isEmpty)
        #expect(h.skips().count == 1)

        h.limits(limitsJSON(allowed: true, five: 0))
        h.clock.advance(by: 60)
        await h.engine.continueNow(threadId: "th1")
        #expect(h.turnStarts().count == 1)
        #expect(h.turnStarts().first.flatMap(h.sentText) == "devam et")
        #expect(!h.notes.contains { if case .continueCountdown = $0 { return true } else { return false } })
        // A second click while the first is being confirmed sends nothing.
        await h.engine.continueNow(threadId: "th1")
        #expect(h.turnStarts().count == 1)
    }

    @Test func manualResendReusesTheClientMessageId() async throws {
        let h = try Harness()
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.engine.tick()
        h.clock.advance(by: 10)
        await h.engine.tick()
        await h.run(for: 150)
        #expect(h.notes.contains(.unconfirmed(threadId: "th1")))
        await h.engine.continueNow(threadId: "th1")
        let ids = h.turnStarts().compactMap(h.clientId)
        #expect(ids.count == 2)
        #expect(Set(ids).count == 1)
    }

    /// The tab row follows the continue: confirming, then unconfirmed ("Send again"), and "Send again" works.
    @Test func tabShowsUnconfirmedContinueAndSendAgainWorks() async throws {
        let h = try Harness()
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.engine.tick()
        #expect(h.engine.tabs.map(\.continueStatus) == [nil])
        h.clock.advance(by: 10)
        await h.engine.tick()
        #expect(h.turnStarts().count == 1)
        #expect(h.engine.tabs.map(\.continueStatus) == [.confirming])
        await h.run(for: 150)
        #expect(h.engine.tabs.map(\.continueStatus) == [.unconfirmed])
        #expect(h.engine.tabs.map(\.isGuarded) == [true])
        await h.engine.continueNow(threadId: "th1")
        #expect(h.turnStarts().count == 2)
        #expect(h.engine.tabs.map(\.continueStatus) == [.confirming])
    }

    @Test func cancelledStopShowsAsSettled() async throws {
        let h = try Harness()
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.engine.tick()
        h.engine.cancelNextAction()
        #expect(h.engine.tabs.map(\.continueStatus) == [.settled])
        await h.run(for: 60)
        #expect(h.engine.tabs.map(\.continueStatus) == [.settled])
        #expect(h.turnStarts().isEmpty)
    }

    @Test func pauseBlocksContinues() async throws {
        let h = try Harness()
        h.standardWaitingSetup()
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.engine.tick()
        h.engine.pause(true)
        #expect(h.engine.nextAction == nil)
        await h.run(for: 600)
        #expect(h.turnStarts().isEmpty)
        h.engine.pause(false)
        await h.run(for: 60, step: 10)
        #expect(h.turnStarts().count == 1)
    }

    // MARK: Manual spend through the Engine (spec §8.2)

    @Test func manualSpendConsumesOnceAndReadsAgain() async throws {
        let h = try Harness()
        h.account.scriptQueue(limitsMethod, [.result(limitsJSON(allowed: false, credits: [("c1", nil)]))])
        h.limits(limitsJSON(allowed: true, five: 0))
        h.account.script(consumeMethod, result: #"{"outcome":"reset"}"#)
        let result = await h.engine.useReset(creditId: "c1")
        #expect(result == .outcome(.reset))
        #expect(h.consumes().map { $0.params["creditId"] } == ["c1"])
        let methods = h.account.requests.map(\.method)
        let consumeIndex = try #require(methods.firstIndex(of: consumeMethod))
        #expect(methods[(consumeIndex + 1)...].contains(limitsMethod))
        #expect(h.notes.contains(.resetUsed(.reset)))
        #expect(try JSONStore<LedgerFile>(url: h.dir.url.appending(path: "reset-ledger.json"), schemaVersion: 1).load()?.entries.isEmpty == true)
    }

    @Test func manualSpendIsRefusedInReadOnlyMode() async throws {
        let h = try Harness()
        // An undecodable limits result puts the app in read-only mode.
        h.limits("[]")
        h.account.script(consumeMethod, result: #"{"outcome":"reset"}"#)
        await h.engine.tick()
        #expect(h.engine.health != .full)
        #expect(await h.engine.useReset(creditId: "c1") == .busy)
        #expect(h.consumes().isEmpty)
    }

    @Test func manualSpendIsRefusedWithAnUnusableStateFile() async throws {
        let h = try Harness { dir in
            try Data(#"{"schemaVersion":2}"#.utf8).write(to: dir.appending(path: "state.json"))
        }
        h.limits(limitsJSON(allowed: false, credits: [("c1", nil)]))
        h.account.script(consumeMethod, result: #"{"outcome":"reset"}"#)
        #expect(await h.engine.useReset(creditId: "c1") == .busy)
        #expect(h.consumes().isEmpty)
    }

    @Test func manualSpendWithAPendingLedgerEntryIsBusy() async throws {
        let h = try Harness()
        h.limits(limitsJSON(allowed: false, credits: [("c1", nil)]))
        h.account.script(consumeMethod, result: #"{"outcome":"reset"}"#)
        // After the launch resume, so the entry stays pending (another copy of the app, say).
        await h.engine.bootstrap()
        try JSONStore<LedgerFile>(url: h.dir.url.appending(path: "reset-ledger.json"), schemaVersion: 1).save(LedgerFile(entries: [
            LedgerEntry(idempotencyKey: UUID(), creditId: "c-other", reason: .manual, createdAt: t0, attempts: 1),
        ]))
        #expect(await h.engine.useReset(creditId: "c1") == .busy)
        #expect(h.consumes().isEmpty)
    }

    /// A manual spend that waited behind an automatic one for the same credit sends nothing: the credit
    /// is checked again against a fresh read once it is its turn.
    @Test func manualSpendQueuedBehindAnAutoSpendIsNotSentTwice() async throws {
        let h = try Harness(settings: acceptedSettings { $0.autoSpendEnabled = true })
        h.standardWaitingSetup()
        h.account.scriptQueue(limitsMethod, [.result(limitsJSON(allowed: false, five: 40, weekly: 98, reached: "weekly", credits: [("c1", nil)]))])
        h.limits(limitsJSON(allowed: true, five: 0, weekly: 0))
        h.account.script(consumeMethod, result: #"{"outcome":"reset"}"#, delay: .milliseconds(200))
        let tick = Task { await h.engine.tick() }
        try await waitUntil { h.consumes().count == 1 }
        let manual = await h.engine.useReset(creditId: "c1")
        await tick.value
        #expect(manual == .busy)
        #expect(h.consumes().count == 1)
    }

    @Test func pauseIsSavedAndRestoredAtLaunch() async throws {
        let h = try Harness()
        h.engine.pause(true)
        #expect(try h.storedState().paused)
        h.engine.pause(false)
        #expect(try h.storedState().paused == false)

        let relaunched = try Harness { dir in
            var state = AppState()
            state.paused = true
            try JSONStore<AppState>(url: dir.appending(path: "state.json"), schemaVersion: 1).save(state)
        }
        #expect(relaunched.engine.isPaused)
        relaunched.standardWaitingSetup()
        relaunched.limits(limitsJSON(allowed: true, five: 0))
        await relaunched.engine.tick()
        await relaunched.run(for: 600)
        #expect(relaunched.turnStarts().isEmpty)
        relaunched.engine.pause(false)
        await relaunched.run(for: 60, step: 10)
        #expect(relaunched.turnStarts().count == 1)
    }

    @Test func guardNewTabsAutomatically() async throws {
        let h = try Harness(settings: acceptedSettings { $0.guardNewTabsAutomatically = true })
        h.standardWaitingSetup(guarded: false)
        h.limits(limitsJSON(allowed: false))
        await h.engine.tick()
        #expect(try h.storedState().guardedTabs.map(\.ref) == [ref()])
        // Unticked by the owner: not added back while the tab lives.
        h.engine.setGuarded(ref(), false)
        await h.run(for: 120)
        #expect(try h.storedState().guardedTabs.isEmpty)
        // A closed guarded tab drops out.
        h.engine.setGuarded(ref(), true)
        h.env.tabs.value = []
        await h.run(for: 30)
        #expect(try h.storedState().guardedTabs.isEmpty)
    }

    // MARK: Guards across a relaunch (bound to the Codex process)

    /// A Harness whose `state.json` already holds a guard (and untick) from an earlier run.
    private func relaunched(guarded: [TabRef], unticked: [TabRef] = []) throws -> Harness {
        try Harness { dir in
            var state = AppState()
            state.guardedTabs = guarded.map { GuardedTab(ref: $0, addedAt: t0.addingTimeInterval(-86_400)) }
            state.untickedTabs = unticked
            try JSONStore<AppState>(url: dir.appending(path: "state.json"), schemaVersion: 1).save(state)
        }
    }

    private func waitAndAllow(_ h: Harness, tabs: [TerminalTab]) async {
        h.sessions.current.value = [waiting()]
        h.env.tabs.value = tabs
        h.loaded(["th1"])
        h.limits(limitsJSON(allowed: true, five: 0))
        await h.engine.tick()
        await h.run(for: 300, step: 10)
    }

    @Test func relaunchWithAnotherProcessOnTheSameTtyIsNotGuarded() async throws {
        let h = try relaunched(guarded: [ref(pid: 100)])
        await waitAndAllow(h, tabs: [tab(pid: 200)])
        #expect(h.turnStarts().isEmpty)
        #expect(h.engine.tabs.map(\.isGuarded) == [false])
        #expect(try h.storedState().guardedTabs.isEmpty)
    }

    @Test func reusedPidWithAnotherStartTimeIsNotGuarded() async throws {
        let h = try relaunched(guarded: [ref(pid: 100, started: "Mon Oct 27 09:00:00 2026")])
        await waitAndAllow(h, tabs: [tab(pid: 100, started: "Wed Oct 29 10:00:00 2026")])
        #expect(h.turnStarts().isEmpty)
        #expect(h.engine.tabs.map(\.isGuarded) == [false])
        #expect(try h.storedState().guardedTabs.isEmpty)
    }

    @Test func relaunchWithTheSameProcessKeepsTheGuard() async throws {
        let h = try relaunched(guarded: [ref()])
        await waitAndAllow(h, tabs: [tab()])
        #expect(h.turnStarts().count == 1)
        #expect(h.engine.tabs.map(\.isGuarded) == [true])
        #expect(try h.storedState().guardedTabs.map(\.ref) == [ref()])
    }

    @Test func untickDoesNotCarryOverToAnotherProcess() async throws {
        let h = try relaunched(guarded: [], unticked: [ref(pid: 100)])
        h.settings.value = acceptedSettings { $0.guardNewTabsAutomatically = true }
        await waitAndAllow(h, tabs: [tab(pid: 200)])
        #expect(try h.storedState().untickedTabs.isEmpty)
        #expect(try h.storedState().guardedTabs.map(\.ref) == [ref(pid: 200)])
    }

    @Test func legacyGuardWithoutPidIsDropped() async throws {
        let legacy = TabRef(windowId: 0, tabIndex: 0, tty: tty1)
        let h = try relaunched(guarded: [legacy], unticked: [legacy])
        h.env.tabs.value = []
        await h.engine.bootstrap()
        #expect(try h.storedState().guardedTabs.isEmpty)
        #expect(try h.storedState().untickedTabs.isEmpty)
        await waitAndAllow(h, tabs: [tab()])
        #expect(h.turnStarts().isEmpty)
        #expect(h.engine.tabs.map(\.isGuarded) == [false])
    }

    @Test func guardOfAProcessGoneAtLaunchIsDropped() async throws {
        let h = try relaunched(guarded: [ref()])
        h.env.tabs.value = []
        await h.engine.bootstrap()
        #expect(try h.storedState().guardedTabs.isEmpty)
    }

    @Test func failedListingAtLaunchKeepsTheGuard() async throws {
        let h = try relaunched(guarded: [ref()])
        h.env.tabs.value = nil
        await h.engine.bootstrap()
        #expect(try h.storedState().guardedTabs.map(\.ref) == [ref()])
    }
}

// MARK: - Polling cadence (spec §5)

@Suite("PollSchedule")
struct PollScheduleTests {
    private func snapshot(five: Double, weekly: Double) -> AccountSnapshot {
        AccountSnapshot(
            ordinaryUsageAllowed: true,
            fiveHour: RateLimitWindow(usedPercent: five, windowMinutes: 300, resetsAt: nil),
            weekly: RateLimitWindow(usedPercent: weekly, windowMinutes: 10_080, resetsAt: nil),
            planType: nil, reachedType: nil, accountId: nil, credits: [], availableCreditCount: 0, readAt: t0)
    }

    @Test func normalIsFiveMinutes() {
        #expect(PollSchedule.nextLimitsRead(after: t0, snapshot: snapshot(five: 10, weekly: 10), stopResets: [], continuePending: false)
            == t0.addingTimeInterval(300))
    }

    @Test func nearLimitOrPendingIsOneMinute() {
        #expect(PollSchedule.nextLimitsRead(after: t0, snapshot: snapshot(five: 90, weekly: 10), stopResets: [], continuePending: false)
            == t0.addingTimeInterval(60))
        #expect(PollSchedule.nextLimitsRead(after: t0, snapshot: snapshot(five: 10, weekly: 10), stopResets: [], continuePending: true)
            == t0.addingTimeInterval(60))
        #expect(PollSchedule.nextLimitsRead(after: t0, snapshot: nil, stopResets: [], continuePending: false)
            == t0.addingTimeInterval(300))
    }

    @Test func readsExactlyAtResetsAt() {
        let reset = t0.addingTimeInterval(20)
        #expect(PollSchedule.nextLimitsRead(after: t0, snapshot: snapshot(five: 100, weekly: 10), stopResets: [reset], continuePending: true)
            == reset)
    }

    @Test func afterResetThirtySecondsThenBackOff() {
        let reset = t0
        let s = snapshot(five: 100, weekly: 10)
        func next(_ elapsed: TimeInterval) -> TimeInterval {
            PollSchedule.nextLimitsRead(after: reset.addingTimeInterval(elapsed), snapshot: s, stopResets: [reset], continuePending: true)
                .timeIntervalSince(reset) - elapsed
        }
        #expect(next(0) == 30)
        #expect(next(290) == 30)
        #expect(next(300) == 60)
        #expect(next(400) == 120)
        #expect(next(600) == 300)
        #expect(next(3000) == 300)
        // An hour after the reset the normal cadence applies again.
        #expect(next(3600) == 60)
    }
}
