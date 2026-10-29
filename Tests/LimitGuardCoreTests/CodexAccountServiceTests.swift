import Foundation
import Testing
@testable import LimitGuardCore

@Suite("CodexAccountService")
struct CodexAccountServiceTests {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeService(_ fake: FakeAppServer) -> CodexAccountService {
        let factory = FakeFactory([fake])
        let client = AppServerClient(
            transportFactory: { factory.make() },
            clientName: "cybokron-limit-guard", clientVersion: "0.1.0", backoff: [.zero])
        let now = fixedNow
        return CodexAccountService(client: client, now: { now })
    }

    @Test func readLimitsUsesMethodName() async throws {
        let fake = FakeAppServer()
        fake.script("account/rateLimits/read", result: String(decoding: try fixture("rate-limits-live.json"), as: UTF8.self))
        let (snapshot, health) = try await makeService(fake).readLimits()
        #expect(fake.requests.last?.method == "account/rateLimits/read")
        #expect(snapshot.readAt == fixedNow)
        #expect(health == .full)
    }

    @Test func readLimitsUndecodableResultIsReadOnly() async throws {
        let fake = FakeAppServer()
        fake.script("account/rateLimits/read", result: "[1,2]")
        let (snapshot, health) = try await makeService(fake).readLimits()
        #expect(snapshot.fiveHour == nil && snapshot.weekly == nil && snapshot.credits.isEmpty)
        #expect(snapshot.readAt == fixedNow)
        guard case .readOnly = health else { Issue.record("expected readOnly, got \(health)"); return }
    }

    @Test func readLimitsRpcErrorThrows() async {
        let fake = FakeAppServer()
        fake.scriptError("account/rateLimits/read", code: -32000, message: "boom")
        await #expect(throws: AppServerError.rpcError(code: -32000, message: "boom")) {
            _ = try await makeService(fake).readLimits()
        }
    }

    @Test func readUsageUsesMethodName() async throws {
        let fake = FakeAppServer()
        fake.script("account/usage/read", result: String(decoding: try fixture("usage-live.json"), as: UTF8.self))
        _ = try await makeService(fake).readUsage()
        #expect(fake.requests.last?.method == "account/usage/read")
    }

    @Test func consumeSendsExactParams() async throws {
        let fake = FakeAppServer()
        fake.script("account/rateLimitResetCredit/consume", result: #"{"outcome":"reset"}"#)
        let key = UUID()
        let outcome = try await makeService(fake).consume(creditId: "credit-1", idempotencyKey: key, timeout: .seconds(2))
        #expect(outcome == .reset)
        let request = try #require(fake.requests.last)
        #expect(request.method == "account/rateLimitResetCredit/consume")
        #expect(request.params == ["idempotencyKey": key.uuidString.lowercased(), "creditId": "credit-1"])
    }

    @Test func consumeUnknownOutcomeReturnsNil() async throws {
        let fake = FakeAppServer()
        fake.script("account/rateLimitResetCredit/consume", result: #"{"outcome":"somethingNew"}"#)
        let outcome = try await makeService(fake).consume(creditId: "c", idempotencyKey: UUID(), timeout: .seconds(2))
        #expect(outcome == nil)
    }

    @Test func consumeTimeoutPassesThroughWithoutRetry() async {
        let fake = FakeAppServer()
        fake.scriptDrop("account/rateLimitResetCredit/consume")
        await #expect(throws: AppServerError.timeout) {
            _ = try await makeService(fake).consume(creditId: "c", idempotencyKey: UUID(), timeout: .milliseconds(200))
        }
        #expect(fake.requests.filter { $0.method == "account/rateLimitResetCredit/consume" }.count == 1)
    }

    @Test func consumeTransportExitPassesThrough() async {
        let fake = FakeAppServer()
        fake.scriptDrop("account/rateLimitResetCredit/consume")
        let service = makeService(fake)
        async let result: ConsumeOutcome? = service.consume(creditId: "c", idempotencyKey: UUID(), timeout: .seconds(5))
        try? await Task.sleep(for: .milliseconds(200))
        fake.simulateExit(7)
        do {
            _ = try await result
            Issue.record("expected throw")
        } catch let error as AppServerError {
            #expect(error == .transportExited(7))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
