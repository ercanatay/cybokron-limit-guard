import Foundation
import Testing
@testable import LimitGuardCore

@Suite("AppServerClient")
struct AppServerClientTests {
    private func makeClient(_ fakes: [FakeAppServer], backoff: [Duration] = [.zero]) -> (AppServerClient, FakeFactory) {
        let factory = FakeFactory(fakes)
        let client = AppServerClient(
            transportFactory: { factory.make() },
            clientName: "cybokron-limit-guard",
            clientVersion: "0.1.0",
            backoff: backoff)
        return (client, factory)
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @Test func handshakeThenRequest() async throws {
        let fake = FakeAppServer()
        fake.script("account/rateLimits/read", result: #"{"ok":true}"#)
        let (client, _) = makeClient([fake])
        let result = try await client.request("account/rateLimits/read", timeout: .seconds(2))
        #expect(json(result)["ok"] as? Bool == true)

        let lines = fake.sentLines
        #expect(lines.count == 3)
        let first = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(first["method"] as? String == "initialize")
        let info = try #require((first["params"] as? [String: Any])?["clientInfo"] as? [String: Any])
        #expect(info["name"] as? String == "cybokron-limit-guard")
        #expect(info["version"] as? String == "0.1.0")
        let second = try #require(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        #expect(second["method"] as? String == "initialized")
        #expect(second["id"] == nil)
        #expect(fake.requests.last?.method == "account/rateLimits/read")
        #expect(fake.wasStarted)
    }

    @Test func handshakeHappensOnlyOncePerTransport() async throws {
        let fake = FakeAppServer()
        fake.script("a")
        let (client, _) = makeClient([fake])
        _ = try await client.request("a", timeout: .seconds(2))
        _ = try await client.request("a", timeout: .seconds(2))
        #expect(fake.requests.filter { $0.method == "initialize" }.count == 1)
    }

    @Test func matchesResponsesById() async throws {
        let fake = FakeAppServer()
        fake.script("slow", result: #"{"who":"slow"}"#, delay: .milliseconds(150))
        fake.script("fast", result: #"{"who":"fast"}"#, delay: .milliseconds(10))
        let (client, _) = makeClient([fake])
        async let slow = client.request("slow", timeout: .seconds(2))
        async let fast = client.request("fast", timeout: .seconds(2))
        let (s, f) = try await (slow, fast)
        #expect(json(s)["who"] as? String == "slow")
        #expect(json(f)["who"] as? String == "fast")
    }

    @Test func timesOut() async throws {
        let fake = FakeAppServer()
        fake.scriptDrop("never")
        let (client, _) = makeClient([fake])
        await #expect(throws: AppServerError.timeout) {
            _ = try await client.request("never", timeout: .milliseconds(50))
        }
    }

    @Test func timedOutHandshakeIsRetriedOnFreshTransport() async throws {
        let stuck = FakeAppServer()
        stuck.scriptDrop("initialize")
        let healthy = FakeAppServer()
        healthy.script("a", result: "1")
        let (client, factory) = makeClient([stuck, healthy])
        await #expect(throws: AppServerError.timeout) {
            _ = try await client.request("a", timeout: .milliseconds(50))
        }
        #expect(stuck.wasStopped)
        let result = try await client.request("a", timeout: .seconds(2))
        #expect(String(decoding: result, as: UTF8.self) == "1")
        #expect(factory.created.count == 2)
    }

    @Test func restartsAfterExit() async throws {
        let first = FakeAppServer()
        first.script("a", result: "1")
        let second = FakeAppServer()
        second.script("a", result: "2")
        let (client, factory) = makeClient([first, second])
        let one = try await client.request("a", timeout: .seconds(2))
        #expect(String(decoding: one, as: UTF8.self) == "1")

        first.simulateExit(1)
        for _ in 0..<100 where await client.isConnected { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await client.isConnected == false)

        let two = try await client.request("a", timeout: .seconds(2))
        #expect(String(decoding: two, as: UTF8.self) == "2")
        #expect(factory.created.count == 2)
        #expect(second.requests.first?.method == "initialize")
        #expect(second.sentLines.count == 3)
    }

    @Test func exitFailsInFlightRequest() async throws {
        let fake = FakeAppServer()
        fake.scriptDrop("hang")
        let (client, _) = makeClient([fake])
        let hung = Task { try await client.request("hang", timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        fake.simulateExit(7)
        await #expect(throws: AppServerError.transportExited(7)) { _ = try await hung.value }
    }

    @Test func backoffDelaysRestart() async throws {
        let first = FakeAppServer()
        first.script("a")
        let (client, _) = makeClient([first, FakeAppServer()], backoff: [.seconds(10)])
        _ = try await client.request("a", timeout: .seconds(2))
        first.simulateExit(1)
        for _ in 0..<100 where await client.isConnected { try await Task.sleep(for: .milliseconds(10)) }
        await #expect(throws: AppServerError.timeout) {
            _ = try await client.request("a", timeout: .milliseconds(100))
        }
    }

    @Test func rpcErrorSurfaces() async throws {
        let fake = FakeAppServer()
        fake.scriptError("bad", code: -32600, message: "x")
        let (client, _) = makeClient([fake])
        await #expect(throws: AppServerError.rpcError(code: -32600, message: "x")) {
            _ = try await client.request("bad", timeout: .seconds(2))
        }
    }

    @Test func notificationsAreNotResponses() async throws {
        let fake = FakeAppServer()
        fake.script("slow", result: #"{"v":1}"#, delay: .milliseconds(100))
        let (client, _) = makeClient([fake])
        async let result = client.request("slow", timeout: .seconds(2))
        try await Task.sleep(for: .milliseconds(30))
        fake.emit(#"{"method":"account/rateLimits/updated","params":{"id":2}}"#)
        fake.emit(#"{"id":2,"method":"server/request","params":{}}"#)
        #expect(json(try await result)["v"] as? Int == 1)
    }

    @Test func shutdownStopsTransportAndRefusesRequests() async throws {
        let fake = FakeAppServer()
        fake.script("a")
        let (client, _) = makeClient([fake])
        _ = try await client.request("a", timeout: .seconds(2))
        await client.shutdown()
        #expect(fake.wasStopped)
        await #expect(throws: AppServerError.notStarted) {
            _ = try await client.request("a", timeout: .seconds(1))
        }
    }
}
