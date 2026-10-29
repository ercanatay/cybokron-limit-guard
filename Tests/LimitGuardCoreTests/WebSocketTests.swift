import Foundation
import Testing
@testable import LimitGuardCore

@Suite("WebSocketFrame")
struct WebSocketFrameTests {
    private let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]

    @Test func encodesRFCExamples() {
        // RFC 6455 §5.7: "Hello", unmasked and masked with 37 fa 21 3d.
        let hello = Data("Hello".utf8)
        #expect(WebSocketFrame.encode(opcode: .text, payload: hello, maskKey: nil)
            == Data([0x81, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F]))
        #expect(WebSocketFrame.encode(opcode: .text, payload: hello, maskKey: mask)
            == Data([0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58]))
    }

    @Test func usesSevenSixteenAndSixtyFourBitLengths() {
        let small = WebSocketFrame.encode(opcode: .text, payload: Data(count: 125), maskKey: mask)
        #expect(Array(small.prefix(2)) == [0x81, 0x80 | 125])
        #expect(small.count == 2 + 4 + 125)

        let medium = WebSocketFrame.encode(opcode: .text, payload: Data(count: 126), maskKey: mask)
        #expect(Array(medium.prefix(4)) == [0x81, 0x80 | 126, 0x00, 126])
        #expect(medium.count == 4 + 4 + 126)

        let mediumMax = WebSocketFrame.encode(opcode: .text, payload: Data(count: 65535), maskKey: nil)
        #expect(Array(mediumMax.prefix(4)) == [0x81, 126, 0xFF, 0xFF])

        let large = WebSocketFrame.encode(opcode: .text, payload: Data(count: 65536), maskKey: mask)
        #expect(Array(large.prefix(10)) == [0x81, 0x80 | 127, 0, 0, 0, 0, 0, 0x01, 0x00, 0x00])
        #expect(large.count == 10 + 4 + 65536)
    }

    @Test func maskedFramesRoundTripAtEveryLength() throws {
        for size in [0, 1, 125, 126, 127, 65535, 65536, 70000] {
            let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            var decoder = WebSocketDecoder()
            let events = try decoder.feed(WebSocketFrame.encode(opcode: .text, payload: payload, maskKey: mask))
            #expect(events == [.text(payload)], "size \(size)")
        }
    }

    @Test func decodesAFrameSplitAcrossReads() throws {
        let payload = Data(String(repeating: "x", count: 300).utf8)
        let wire = WebSocketFrame.encode(opcode: .text, payload: payload, maskKey: nil)
            + WebSocketFrame.encode(opcode: .text, payload: Data("second".utf8), maskKey: nil)
        var decoder = WebSocketDecoder()
        var events: [WebSocketEvent] = []
        for byte in wire { events += try decoder.feed(Data([byte])) }
        #expect(events == [.text(payload), .text(Data("second".utf8))])
    }

    @Test func joinsAFragmentedMessageAroundAPing() throws {
        let wire = WebSocketFrame.encode(opcode: .text, payload: Data(#"{"id":"#.utf8), maskKey: nil, fin: false)
            + WebSocketFrame.encode(opcode: .ping, payload: Data("p".utf8), maskKey: nil)
            + WebSocketFrame.encode(opcode: .continuation, payload: Data("1".utf8), maskKey: nil, fin: false)
            + WebSocketFrame.encode(opcode: .continuation, payload: Data("}".utf8), maskKey: nil)
        var decoder = WebSocketDecoder()
        let events = try decoder.feed(wire)
        #expect(events == [.ping(Data("p".utf8)), .text(Data(#"{"id":1}"#.utf8))])
    }

    @Test func decodesClose() throws {
        var decoder = WebSocketDecoder()
        let events = try decoder.feed(WebSocketFrame.close(code: 1000, maskKey: nil))
        #expect(events == [.close(code: 1000)])
        var empty = WebSocketDecoder()
        #expect(try empty.feed(WebSocketFrame.encode(opcode: .close, payload: Data(), maskKey: nil)) == [.close(code: nil)])
    }

    @Test func rejectsProtocolViolations() {
        var stray = WebSocketDecoder()
        #expect(throws: WebSocketProtocolError.unexpectedContinuation) {
            try stray.feed(WebSocketFrame.encode(opcode: .continuation, payload: Data("x".utf8), maskKey: nil))
        }
        var reserved = WebSocketDecoder()
        #expect(throws: WebSocketProtocolError.unknownOpcode(3)) { try reserved.feed(Data([0x83, 0x00])) }
        var fragmentedPing = WebSocketDecoder()
        #expect(throws: WebSocketProtocolError.invalidControlFrame) {
            try fragmentedPing.feed(WebSocketFrame.encode(opcode: .ping, payload: Data(), maskKey: nil, fin: false))
        }
        var tooLarge = WebSocketDecoder(maxMessageSize: 10)
        #expect(throws: WebSocketProtocolError.messageTooLarge) {
            try tooLarge.feed(WebSocketFrame.encode(opcode: .text, payload: Data(count: 11), maskKey: nil))
        }
    }

    @Test func computesTheRFCAcceptValue() {
        #expect(WebSocketHandshake.acceptValue(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func buildsAnUpgradeRequestWithAFreshKey() {
        let key = WebSocketHandshake.makeKey()
        #expect(Data(base64Encoded: key)?.count == 16)
        #expect(key != WebSocketHandshake.makeKey())
        let request = String(decoding: WebSocketHandshake.request(key: key), as: UTF8.self)
        #expect(request.hasPrefix("GET / HTTP/1.1\r\n"))
        #expect(request.contains("\r\nUpgrade: websocket\r\n"))
        #expect(request.contains("\r\nConnection: Upgrade\r\n"))
        #expect(request.contains("\r\nSec-WebSocket-Key: \(key)\r\n"))
        #expect(request.contains("\r\nSec-WebSocket-Version: 13\r\n"))
        #expect(request.hasSuffix("\r\n\r\n"))
    }

    @Test func validatesTheUpgradeResponse() {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let good = "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"
        #expect(WebSocketHandshake.validate(head: Data(good.utf8), key: key))
        let wrongAccept = good.replacingOccurrences(of: "s3pP", with: "AAAA")
        #expect(!WebSocketHandshake.validate(head: Data(wrongAccept.utf8), key: key))
        let notUpgraded = good.replacingOccurrences(of: "101 Switching Protocols", with: "400 Bad Request")
        #expect(!WebSocketHandshake.validate(head: Data(notUpgraded.utf8), key: key))
    }
}

/// Plays the server side of the proxy: answers the upgrade, then decodes client frames and lets the test reply.
private final class FakeProxyChannel: ByteChannel, @unchecked Sendable {
    enum Upgrade {
        case accept
        case wrongAccept
        case refuse
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "fake-proxy")
    private var _onData: (@Sendable (Data) -> Void)?
    private var _onExit: (@Sendable (Int32) -> Void)?
    private var requestHead = Data()
    private var upgraded = false
    private var decoder = WebSocketDecoder()
    private var _clientEvents: [WebSocketEvent] = []
    private var _rawWrites: [Data] = []
    private var _stopped = false
    let upgrade: Upgrade
    /// Sent in the same chunk as the 101 response.
    let firstFrames: Data

    init(upgrade: Upgrade = .accept, firstFrames: Data = Data()) {
        self.upgrade = upgrade
        self.firstFrames = firstFrames
    }

    var onData: (@Sendable (Data) -> Void)? {
        get { lock.withLock { _onData } }
        set { lock.withLock { _onData = newValue } }
    }

    var onExit: (@Sendable (Int32) -> Void)? {
        get { lock.withLock { _onExit } }
        set { lock.withLock { _onExit = newValue } }
    }

    var clientEvents: [WebSocketEvent] { lock.withLock { _clientEvents } }
    var rawWrites: [Data] { lock.withLock { _rawWrites } }
    var stopped: Bool { lock.withLock { _stopped } }

    func start() throws {}

    func stop() { lock.withLock { _stopped = true } }

    func write(_ data: Data) throws {
        let reply: Data? = try lock.withLock {
            _rawWrites.append(data)
            if !upgraded {
                requestHead.append(data)
                guard let end = requestHead.range(of: Data("\r\n\r\n".utf8)) else { return nil }
                upgraded = true
                let head = String(decoding: requestHead[..<end.lowerBound], as: UTF8.self)
                let key = head.components(separatedBy: "\r\n")
                    .first { $0.hasPrefix("Sec-WebSocket-Key: ") }
                    .map { String($0.dropFirst("Sec-WebSocket-Key: ".count)) } ?? ""
                switch upgrade {
                case .accept:
                    let accept = WebSocketHandshake.acceptValue(for: key)
                    return Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8) + firstFrames
                case .wrongAccept:
                    return Data("HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: bm9wZQ==\r\n\r\n".utf8)
                case .refuse:
                    return Data("HTTP/1.1 404 Not Found\r\n\r\n".utf8)
                }
            }
            _clientEvents += try decoder.feed(data)
            return nil
        }
        if let reply { serverSends(reply) }
    }

    /// Delivers bytes to the transport asynchronously (in order), like the reader thread does.
    func serverSends(_ data: Data) {
        queue.async { [weak self] in self?.onData?(data) }
    }

    func exit(_ status: Int32) {
        queue.async { [weak self] in self?.onExit?(status) }
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    private var _exits: [Int32] = []
    func line(_ data: Data) { lock.withLock { _lines.append(String(decoding: data, as: UTF8.self)) } }
    func exit(_ status: Int32) { lock.withLock { _exits.append(status) } }
    var lines: [String] { lock.withLock { _lines } }
    var exits: [Int32] { lock.withLock { _exits } }
}

private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
}

@Suite("WebSocketTransport")
struct WebSocketTransportTests {
    private func connect(_ channel: FakeProxyChannel) throws -> (WebSocketTransport, Received) {
        let transport = WebSocketTransport(channel: channel)
        let received = Received()
        transport.onLine = { received.line($0) }
        transport.onExit = { received.exit($0) }
        try transport.start()
        return (transport, received)
    }

    @Test func holdsSendsUntilUpgradedThenSendsOneMaskedFramePerLine() async throws {
        let channel = FakeProxyChannel()
        let (transport, _) = try connect(channel)
        try transport.send(Data("{\"id\":1}\n".utf8))
        try transport.send(Data(#"{"method":"initialized"}"#.utf8))
        try await waitUntil { channel.clientEvents.count == 2 }
        #expect(channel.clientEvents == [.text(Data(#"{"id":1}"#.utf8)), .text(Data(#"{"method":"initialized"}"#.utf8))])
        // The first write is the upgrade request alone; every frame after it is masked.
        let writes = channel.rawWrites
        #expect(String(decoding: writes[0], as: UTF8.self).hasPrefix("GET / HTTP/1.1"))
        for frame in writes.dropFirst() { #expect(frame[frame.startIndex + 1] & 0x80 == 0x80) }
        transport.stop()
    }

    @Test func deliversFramesThatArriveWithTheUpgradeResponse() async throws {
        let first = WebSocketFrame.encode(opcode: .text, payload: Data(#"{"id":7}"#.utf8), maskKey: nil)
        let channel = FakeProxyChannel(firstFrames: first)
        let (transport, received) = try connect(channel)
        try await waitUntil { received.lines.count == 1 }
        channel.serverSends(WebSocketFrame.encode(opcode: .text, payload: Data("{\"id\":".utf8), maskKey: nil, fin: false))
        channel.serverSends(WebSocketFrame.encode(opcode: .continuation, payload: Data("8}".utf8), maskKey: nil))
        try await waitUntil { received.lines.count == 2 }
        #expect(received.lines == [#"{"id":7}"#, #"{"id":8}"#])
        transport.stop()
    }

    @Test func answersPingWithMaskedPong() async throws {
        let channel = FakeProxyChannel()
        let (transport, _) = try connect(channel)
        try await waitUntil { channel.rawWrites.count == 1 }
        try await Task.sleep(for: .milliseconds(20))
        channel.serverSends(WebSocketFrame.encode(opcode: .ping, payload: Data("hb".utf8), maskKey: nil))
        try await waitUntil { channel.clientEvents.count == 1 }
        #expect(channel.clientEvents == [.pong(Data("hb".utf8))])
        transport.stop()
    }

    @Test func closeFrameEndsTheTransportOnce() async throws {
        let channel = FakeProxyChannel()
        let (transport, received) = try connect(channel)
        try await Task.sleep(for: .milliseconds(20))
        channel.serverSends(WebSocketFrame.close(code: 1001, maskKey: nil))
        channel.exit(0)
        try await waitUntil { !received.exits.isEmpty && channel.stopped }
        try await Task.sleep(for: .milliseconds(30))
        #expect(received.exits == [WebSocketTransport.closedByPeerStatus])
        #expect(channel.clientEvents == [.close(code: 1001)])
        #expect(throws: TransportError.notRunning) { try transport.send(Data("{}".utf8)) }
    }

    @Test func wrongAcceptFailsTheConnection() async throws {
        let channel = FakeProxyChannel(upgrade: .wrongAccept)
        let (transport, received) = try connect(channel)
        try await waitUntil { !received.exits.isEmpty }
        #expect(received.exits == [WebSocketTransport.handshakeFailedStatus])
        #expect(channel.stopped)
        transport.stop()
    }

    @Test func refusedUpgradeFailsTheConnection() async throws {
        let channel = FakeProxyChannel(upgrade: .refuse)
        let (transport, received) = try connect(channel)
        try await waitUntil { !received.exits.isEmpty }
        #expect(received.exits == [WebSocketTransport.handshakeFailedStatus])
        transport.stop()
    }

    @Test func proxyExitIsReportedButNotAfterStop() async throws {
        let channel = FakeProxyChannel()
        let (transport, received) = try connect(channel)
        channel.exit(1)
        try await waitUntil { !received.exits.isEmpty }
        #expect(received.exits == [1])
        transport.stop()

        let quiet = FakeProxyChannel()
        let (stopped, silent) = try connect(quiet)
        stopped.stop()
        quiet.exit(1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(silent.exits.isEmpty)
    }

    @Test func appServerClientWorksOverTheTransport() async throws {
        let channel = FakeProxyChannel()
        let echo = Task {
            // A tiny server: answer each request with its own method name.
            var answered = 0
            while answered < 2 {
                try await Task.sleep(for: .milliseconds(5))
                let requests = channel.clientEvents.compactMap { event -> [String: Any]? in
                    guard case .text(let data) = event else { return nil }
                    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }.filter { $0["id"] != nil }
                for request in requests.dropFirst(answered) {
                    let id = request["id"] as! Int
                    let method = request["method"] as! String
                    channel.serverSends(WebSocketFrame.encode(
                        opcode: .text, payload: Data(#"{"id":\#(id),"result":{"m":"\#(method)"}}"#.utf8), maskKey: nil))
                    answered += 1
                }
            }
        }
        let client = AppServerClient(transportFactory: { WebSocketTransport(channel: channel) },
                                     clientName: "test", clientVersion: "0")
        let result = try await client.request("thread/loaded/list", params: [:], timeout: .seconds(5))
        #expect(String(decoding: result, as: UTF8.self) == #"{"m":"thread\/loaded\/list"}"#
            || String(decoding: result, as: UTF8.self) == #"{"m":"thread/loaded/list"}"#)
        try await echo.value
        await client.shutdown()
    }
}
