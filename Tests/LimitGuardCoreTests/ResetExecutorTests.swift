import Foundation
import Testing
@testable import LimitGuardCore

/// Thread-safe recorder for values captured inside fakes and sleepers.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@Suite("ResetExecutor")
struct ResetExecutorTests {
    private static let consume = "account/rateLimitResetCredit/consume"
    private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

    private func ledgerStore(_ dir: TemporaryDirectory) -> JSONStore<LedgerFile> {
        JSONStore(url: dir.url.appending(path: "reset-ledger.json"), schemaVersion: 1)
    }

    private func makeService(_ fakes: [FakeAppServer]) -> CodexAccountService {
        let factory = FakeFactory(fakes)
        let client = AppServerClient(
            transportFactory: { factory.make() },
            clientName: "cybokron-limit-guard", clientVersion: "0.1.0", backoff: [.zero])
        let now = fixedNow
        return CodexAccountService(client: client, now: { now })
    }

    private func makeExecutor(
        _ fakes: [FakeAppServer], ledger: ResetLedger, delays: Box<[Duration]> = Box([]),
        consumeTimeout: Duration = .seconds(2)
    ) -> ResetExecutor {
        let now = fixedNow
        return ResetExecutor(
            service: makeService(fakes), ledger: ledger, now: { now },
            consumeTimeout: consumeTimeout,
            sleeper: { delay in delays.value.append(delay) })
    }

    private func consumeRequests(_ fake: FakeAppServer) -> [FakeAppServer.Request] {
        fake.requests.filter { $0.method == Self.consume }
    }

    @Test func ledgerWrittenBeforeCall() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let store = ledgerStore(dir)
        let fake = FakeAppServer()
        fake.script(Self.consume, result: #"{"outcome":"reset"}"#)
        let seen = Box<[LedgerEntry]?>(nil)
        fake.onRequest = { request in
            if request.method == Self.consume { seen.value = (try? store.load())?.entries }
        }
        let result = await makeExecutor([fake], ledger: ResetLedger(store: store)).spend(creditId: "c1", reason: .auto)
        #expect(result == .outcome(.reset))
        let entries = try #require(seen.value)
        #expect(entries.count == 1)
        #expect(entries.first?.creditId == "c1")
        #expect(entries.first?.reason == .auto)
        #expect(entries.first?.attempts == 1)
        #expect(entries.first?.createdAt == fixedNow)
        let request = try #require(consumeRequests(fake).first)
        #expect(request.params["idempotencyKey"] == entries.first?.idempotencyKey.uuidString.lowercased())
    }

    @Test(arguments: [
        ("reset", ConsumeOutcome.reset), ("nothingToReset", .nothingToReset),
        ("noCredit", .noCredit), ("alreadyRedeemed", .alreadyRedeemed),
    ])
    func finalOutcomeClearsLedger(raw: String, outcome: ConsumeOutcome) async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let fake = FakeAppServer()
        fake.script(Self.consume, result: #"{"outcome":"\#(raw)"}"#)
        let ledger = ResetLedger(store: ledgerStore(dir))
        let result = await makeExecutor([fake], ledger: ledger).spend(creditId: "c1", reason: .manual)
        #expect(result == .outcome(outcome))
        #expect(try await ledger.pending() == nil)
        #expect(try ledgerStore(dir).load()?.entries == [])
        #expect(consumeRequests(fake).count == 1)
    }

    @Test func timeoutRetriesWithSameKey() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let fake = FakeAppServer()
        fake.scriptQueue(Self.consume, [.drop, .drop, .result(#"{"outcome":"reset"}"#)])
        let delays = Box<[Duration]>([])
        let ledger = ResetLedger(store: ledgerStore(dir))
        let result = await makeExecutor([fake], ledger: ledger, delays: delays, consumeTimeout: .milliseconds(150)).spend(creditId: "c1", reason: .auto)
        #expect(result == .outcome(.reset))
        let requests = consumeRequests(fake)
        #expect(requests.count == 3)
        #expect(Set(requests.map(\.params)).count == 1)
        #expect(requests.first?.params["creditId"] == "c1")
        #expect(delays.value == [.seconds(10), .seconds(60)])
        #expect(try await ledger.pending() == nil)
    }

    @Test func exhaustedRetriesKeepEntry() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let fake = FakeAppServer()
        fake.scriptDrop(Self.consume)
        let delays = Box<[Duration]>([])
        let ledger = ResetLedger(store: ledgerStore(dir))
        let result = await makeExecutor([fake], ledger: ledger, delays: delays, consumeTimeout: .milliseconds(150)).spend(creditId: "c1", reason: .auto)
        #expect(result == .unknown)
        #expect(consumeRequests(fake).count == 4)
        #expect(Set(consumeRequests(fake).map(\.params)).count == 1)
        #expect(delays.value == [.seconds(10), .seconds(60), .seconds(240)])
        let entry = try #require(try await ledger.pending())
        #expect(entry.attempts == 4)
        #expect(entry.creditId == "c1")
    }

    @Test func transportExitRetriesWithSameKey() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let first = FakeAppServer()
        first.scriptDrop(Self.consume)
        first.onRequest = { [weak first] request in
            if request.method == Self.consume { first?.simulateExit(9) }
        }
        let second = FakeAppServer()
        second.script(Self.consume, result: #"{"outcome":"reset"}"#)
        let ledger = ResetLedger(store: ledgerStore(dir))
        let result = await makeExecutor([first, second], ledger: ledger).spend(creditId: "c1", reason: .auto)
        #expect(result == .outcome(.reset))
        let a = try #require(consumeRequests(first).first)
        let b = try #require(consumeRequests(second).first)
        #expect(a.params == b.params)
        #expect(try await ledger.pending() == nil)
    }

    @Test func unknownOutcomeKeepsEntry() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let fake = FakeAppServer()
        fake.script(Self.consume, result: #"{"outcome":"somethingNew"}"#)
        let ledger = ResetLedger(store: ledgerStore(dir))
        let result = await makeExecutor([fake], ledger: ledger).spend(creditId: "c1", reason: .auto)
        #expect(result == .unknown)
        #expect(consumeRequests(fake).count == 1)
        #expect(try await ledger.pending()?.creditId == "c1")
    }

    @Test func rpcErrorClearsEntryWithoutRetry() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let fake = FakeAppServer()
        fake.scriptError(Self.consume, code: -32000, message: "boom")
        let ledger = ResetLedger(store: ledgerStore(dir))
        let result = await makeExecutor([fake], ledger: ledger).spend(creditId: "c1", reason: .auto)
        #expect(result == .unknown)
        #expect(consumeRequests(fake).count == 1)
        #expect(try await ledger.pending() == nil)
    }

    @Test func pendingLedgerEntryIsRetriedWithSameKey() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let dropping = FakeAppServer()
        dropping.scriptDrop(Self.consume)
        let firstRun = await makeExecutor([dropping], ledger: ResetLedger(store: ledgerStore(dir)), consumeTimeout: .milliseconds(150))
            .spend(creditId: "c1", reason: .manual)
        #expect(firstRun == .unknown)
        let stored = try #require(try ledgerStore(dir).load()?.entries.first)

        // A fresh launch: new ledger actor and executor on the same file.
        let fake = FakeAppServer()
        fake.script(Self.consume, result: #"{"outcome":"alreadyRedeemed"}"#)
        let ledger = ResetLedger(store: ledgerStore(dir))
        let resumed = await makeExecutor([fake], ledger: ledger).resumePending()
        #expect(resumed == .outcome(.alreadyRedeemed))
        let request = try #require(consumeRequests(fake).first)
        #expect(request.params == ["idempotencyKey": stored.idempotencyKey.uuidString.lowercased(), "creditId": "c1"])
        #expect(try await ledger.pending() == nil)
    }

    @Test func resumeWithoutPendingReturnsNil() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let fake = FakeAppServer()
        let result = await makeExecutor([fake], ledger: ResetLedger(store: ledgerStore(dir))).resumePending()
        #expect(result == nil)
        #expect(consumeRequests(fake).isEmpty)
    }

    @Test func secondSpendWhilePendingIsBusy() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        // A stored entry from an earlier run blocks a new spend.
        let ledger = ResetLedger(store: ledgerStore(dir))
        _ = try await ledger.begin(creditId: "old", reason: .auto, now: fixedNow)
        let idle = FakeAppServer()
        #expect(await makeExecutor([idle], ledger: ledger).spend(creditId: "c2", reason: .manual) == .busy)
        #expect(consumeRequests(idle).isEmpty)
        #expect(try await ledger.pending()?.creditId == "old")
    }

    @Test func concurrentSpendIsBusy() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let fake = FakeAppServer()
        fake.script(Self.consume, result: #"{"outcome":"reset"}"#, delay: .milliseconds(100))
        let executor = makeExecutor([fake], ledger: ResetLedger(store: ledgerStore(dir)))
        async let first = executor.spend(creditId: "c1", reason: .auto)
        async let second = executor.spend(creditId: "c2", reason: .manual)
        let results = await [first, second]
        #expect(results.filter { $0 == .busy }.count == 1)
        #expect(results.filter { $0 == .outcome(.reset) }.count == 1)
        #expect(consumeRequests(fake).count == 1)
    }

    @Test func ledgerOlderThan24hExpires() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let ledger = ResetLedger(store: ledgerStore(dir))
        let entry = try await ledger.begin(creditId: "c1", reason: .auto, now: fixedNow)
        #expect(try await ledger.expireOlderThan(24 * 3600, now: fixedNow.addingTimeInterval(24 * 3600)) == [])
        #expect(try await ledger.pending() == entry)
        let expired = try await ledger.expireOlderThan(24 * 3600, now: fixedNow.addingTimeInterval(24 * 3600 + 1))
        #expect(expired == [entry])
        #expect(try await ledger.pending() == nil)
        #expect(try ledgerStore(dir).load()?.entries == [])
    }

    @Test func spendAndResumeTogetherSendOnlyThePendingKey() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let stored = LedgerEntry(idempotencyKey: UUID(), creditId: "c-stored", reason: .auto, createdAt: fixedNow, attempts: 1)
        try ledgerStore(dir).save(LedgerFile(entries: [stored]))
        let fake = FakeAppServer()
        fake.script(Self.consume, result: #"{"outcome":"reset"}"#, delay: .milliseconds(100))
        let store = ledgerStore(dir)
        let ledgerSizes = Box<[Int]>([])
        fake.onRequest = { request in
            if request.method == Self.consume { ledgerSizes.value.append((try? store.load())?.entries.count ?? -1) }
        }
        let executor = makeExecutor([fake], ledger: ResetLedger(store: store))
        async let spent = executor.spend(creditId: "c-new", reason: .manual)
        async let resumed = executor.resumePending()
        let (spend, resume) = await (spent, resumed)
        // The new spend never runs while an entry is pending; the resume either ran or found the executor busy.
        #expect(spend == .busy)
        #expect(resume == .outcome(.reset) || resume == .busy)
        let requests = consumeRequests(fake)
        #expect(requests.count <= 1)
        #expect(requests.allSatisfy { $0.params == ["idempotencyKey": stored.idempotencyKey.uuidString.lowercased(), "creditId": "c-stored"] })
        #expect(ledgerSizes.value.allSatisfy { $0 == 1 })
    }

    @Test func twoExecutorsOnOneLedgerSpendOnce() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let store = ledgerStore(dir)
        let ledger = ResetLedger(store: store)
        let ledgerSizes = Box<[Int]>([])
        let fakes = [FakeAppServer(), FakeAppServer()]
        for fake in fakes {
            fake.script(Self.consume, result: #"{"outcome":"reset"}"#, delay: .milliseconds(100))
            fake.onRequest = { request in
                if request.method == Self.consume { ledgerSizes.value.append((try? store.load())?.entries.count ?? -1) }
            }
        }
        let a = makeExecutor([fakes[0]], ledger: ledger)
        let b = makeExecutor([fakes[1]], ledger: ledger)
        async let first = a.spend(creditId: "c1", reason: .auto)
        async let second = b.spend(creditId: "c2", reason: .manual)
        let results = await [first, second]
        #expect(results.filter { $0 == .busy }.count == 1)
        #expect(results.filter { $0 == .outcome(.reset) }.count == 1)
        #expect(fakes.map { consumeRequests($0).count }.reduce(0, +) == 1)
        #expect(ledgerSizes.value == [1])
        #expect(try await ledger.pending() == nil)
    }

    @Test func secondExecutorResumingAnInFlightSpendUsesTheSameKey() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let store = ledgerStore(dir)
        let ledger = ResetLedger(store: store)
        let ledgerSizes = Box<[Int]>([])
        let fakes = [FakeAppServer(), FakeAppServer()]
        for fake in fakes {
            fake.script(Self.consume, result: #"{"outcome":"reset"}"#, delay: .milliseconds(100))
            fake.onRequest = { request in
                if request.method == Self.consume { ledgerSizes.value.append((try? store.load())?.entries.count ?? -1) }
            }
        }
        let a = makeExecutor([fakes[0]], ledger: ledger)
        let b = makeExecutor([fakes[1]], ledger: ledger)
        async let spent = a.spend(creditId: "c1", reason: .manual)
        async let resumed = b.resumePending()
        _ = await (spent, resumed)
        let keys = fakes.flatMap(consumeRequests).map { $0.params["idempotencyKey"] }
        #expect(!keys.isEmpty)
        #expect(Set(keys).count == 1)
        #expect(fakes.flatMap(consumeRequests).allSatisfy { $0.params["creditId"] == "c1" })
        #expect(ledgerSizes.value.allSatisfy { $0 == 1 })
    }

    @Test func twoLedgersOnOneFileNeverHoldTwoKeys() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let a = ResetLedger(store: ledgerStore(dir))
        let b = ResetLedger(store: ledgerStore(dir))
        #expect(try await a.pending() == nil)
        let entryB = try await b.begin(creditId: "c1", reason: .auto, now: fixedNow)
        await #expect(throws: LedgerError.entryPending) {
            _ = try await a.begin(creditId: "c2", reason: .manual, now: fixedNow)
        }
        #expect(try await a.pending() == entryB)
        #expect(try ledgerStore(dir).load()?.entries == [entryB])
    }

    @Test func unreadableLedgerSendsNothing() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        try Data(#"{"schemaVersion":2,"entries":[]}"#.utf8).write(to: dir.url.appending(path: "reset-ledger.json"))
        let fake = FakeAppServer()
        let executor = makeExecutor([fake], ledger: ResetLedger(store: ledgerStore(dir)))
        #expect(await executor.resumePending() == .unknown)
        #expect(await executor.spend(creditId: "c1", reason: .auto) == .unknown)
        #expect(consumeRequests(fake).isEmpty)
    }

    @Test func beginRefusesSecondEntry() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let ledger = ResetLedger(store: ledgerStore(dir))
        _ = try await ledger.begin(creditId: "c1", reason: .auto, now: fixedNow)
        await #expect(throws: LedgerError.entryPending) {
            _ = try await ledger.begin(creditId: "c2", reason: .manual, now: fixedNow)
        }
    }

    @Test func ledgerFileHasSchemaVersion() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.remove() }
        let ledger = ResetLedger(store: ledgerStore(dir))
        _ = try await ledger.begin(creditId: "c1", reason: .manual, now: fixedNow)
        let data = try Data(contentsOf: dir.url.appending(path: "reset-ledger.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect((object["entries"] as? [Any])?.count == 1)
    }
}
