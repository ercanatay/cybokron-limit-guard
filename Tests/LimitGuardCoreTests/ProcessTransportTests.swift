import Foundation
import Testing
@testable import LimitGuardCore

@Suite("ProcessTransport")
struct ProcessTransportTests {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private var status: Int32?
        func add(_ data: Data) { lock.withLock { lines.append(String(decoding: data, as: UTF8.self)) } }
        func exit(_ code: Int32) { lock.withLock { status = code } }
        var snapshot: ([String], Int32?) { lock.withLock { (lines, status) } }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func echoesLinesThroughCat() async throws {
        let transport = ProcessTransport(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [])
        let collector = Collector()
        transport.onLine = { collector.add($0) }
        try transport.start()
        try transport.send(Data(#"{"id":1}"#.utf8))
        try transport.send(Data("{\"id\":2}\n".utf8))
        try await wait { collector.snapshot.0.count == 2 }
        transport.stop()
        #expect(collector.snapshot.0 == [#"{"id":1}"#, #"{"id":2}"#])
        #expect(throws: TransportError.notRunning) { try transport.send(Data("x".utf8)) }
    }

    @Test func reportsExitStatus() async throws {
        let transport = ProcessTransport(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo hi; exit 3"])
        let collector = Collector()
        transport.onLine = { collector.add($0) }
        transport.onExit = { collector.exit($0) }
        try transport.start()
        try await wait { collector.snapshot.1 != nil }
        #expect(collector.snapshot.0 == ["hi"])
        #expect(collector.snapshot.1 == 3)
    }
}
