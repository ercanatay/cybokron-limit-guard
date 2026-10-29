import CryptoKit
import Foundation

/// RFC 6455 opcodes.
public enum WebSocketOpcode: UInt8, Sendable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA

    var isControl: Bool { rawValue & 0x8 != 0 }
}

/// One complete message or control frame from the peer.
public enum WebSocketEvent: Equatable, Sendable {
    case text(Data)
    case binary(Data)
    case ping(Data)
    case pong(Data)
    /// `code` is nil when the close frame carried no status code.
    case close(code: UInt16?)
}

public enum WebSocketProtocolError: Error, Equatable, Sendable {
    case reservedBits
    case unknownOpcode(UInt8)
    /// A continuation frame without a message in progress.
    case unexpectedContinuation
    /// A new text/binary frame while a fragmented message is still open.
    case interleavedDataFrame
    /// A control frame that is fragmented or longer than 125 bytes.
    case invalidControlFrame
    case messageTooLarge
}

/// Encodes single frames. Client frames must carry a mask key; server frames must not.
public enum WebSocketFrame {
    public static func encode(opcode: WebSocketOpcode, payload: Data, maskKey: [UInt8]?, fin: Bool = true) -> Data {
        var frame = Data()
        frame.append((fin ? 0x80 : 0x00) | opcode.rawValue)
        let maskBit: UInt8 = maskKey == nil ? 0x00 : 0x80
        let count = payload.count
        if count < 126 {
            frame.append(maskBit | UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(maskBit | 126)
            frame.append(UInt8(count >> 8))
            frame.append(UInt8(count & 0xFF))
        } else {
            frame.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF)) }
        }
        guard let maskKey else {
            frame.append(payload)
            return frame
        }
        precondition(maskKey.count == 4, "a WebSocket mask key is 4 bytes")
        frame.append(contentsOf: maskKey)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ maskKey[$0.offset & 3] })
        return frame
    }

    public static func close(code: UInt16, maskKey: [UInt8]?) -> Data {
        encode(opcode: .close, payload: Data([UInt8(code >> 8), UInt8(code & 0xFF)]), maskKey: maskKey)
    }

    /// A fresh random mask key for a client frame.
    public static func randomMaskKey() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<4).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}

/// Incremental frame decoder: feed it bytes as they arrive, get back complete messages and control
/// frames. Fragmented messages are joined; control frames may arrive between their fragments.
public struct WebSocketDecoder: Sendable {
    private let maxMessageSize: Int
    private var buffer: [UInt8] = []
    private var partialOpcode: WebSocketOpcode?
    private var partial = Data()

    public init(maxMessageSize: Int = 64 << 20) {
        self.maxMessageSize = maxMessageSize
    }

    public mutating func feed(_ data: Data) throws -> [WebSocketEvent] {
        buffer.append(contentsOf: data)
        var events: [WebSocketEvent] = []
        var offset = 0
        defer { buffer.removeFirst(offset) }
        while let consumed = try decodeFrame(at: offset, into: &events) {
            offset += consumed
        }
        return events
    }

    /// Decodes the frame starting at `start`; nil when it is not complete yet.
    private mutating func decodeFrame(at start: Int, into events: inout [WebSocketEvent]) throws -> Int? {
        let available = buffer.count - start
        guard available >= 2 else { return nil }
        let first = buffer[start]
        let second = buffer[start + 1]
        guard first & 0x70 == 0 else { throw WebSocketProtocolError.reservedBits }
        guard let opcode = WebSocketOpcode(rawValue: first & 0x0F) else {
            throw WebSocketProtocolError.unknownOpcode(first & 0x0F)
        }
        let fin = first & 0x80 != 0
        let masked = second & 0x80 != 0
        var headerLength = 2
        var length = UInt64(second & 0x7F)
        if length == 126 {
            guard available >= 4 else { return nil }
            length = UInt64(buffer[start + 2]) << 8 | UInt64(buffer[start + 3])
            headerLength = 4
        } else if length == 127 {
            guard available >= 10 else { return nil }
            length = (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(buffer[start + 2 + $1]) }
            headerLength = 10
        }
        if opcode.isControl, !fin || length > 125 { throw WebSocketProtocolError.invalidControlFrame }
        guard length <= UInt64(maxMessageSize) else { throw WebSocketProtocolError.messageTooLarge }
        let maskLength = masked ? 4 : 0
        let total = headerLength + maskLength + Int(length)
        guard available >= total else { return nil }

        let payloadStart = start + headerLength + maskLength
        var payload = Data(buffer[payloadStart..<(payloadStart + Int(length))])
        if masked {
            let key = Array(buffer[(start + headerLength)..<payloadStart])
            for index in payload.indices { payload[index] ^= key[(index - payload.startIndex) & 3] }
        }

        switch opcode {
        case .ping: events.append(.ping(payload))
        case .pong: events.append(.pong(payload))
        case .close:
            let code = payload.count >= 2 ? UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1]) : nil
            events.append(.close(code: code))
        case .text, .binary:
            guard partialOpcode == nil else { throw WebSocketProtocolError.interleavedDataFrame }
            if fin {
                events.append(opcode == .text ? .text(payload) : .binary(payload))
            } else {
                partialOpcode = opcode
                partial = payload
            }
        case .continuation:
            guard let messageOpcode = partialOpcode else { throw WebSocketProtocolError.unexpectedContinuation }
            guard partial.count + payload.count <= maxMessageSize else { throw WebSocketProtocolError.messageTooLarge }
            partial.append(payload)
            if fin {
                events.append(messageOpcode == .text ? .text(partial) : .binary(partial))
                partialOpcode = nil
                partial = Data()
            }
        }
        return total
    }
}

/// The HTTP/1.1 upgrade that opens a WebSocket over the `codex app-server proxy` byte stream.
public enum WebSocketHandshake {
    static let acceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// 16 random bytes, base64-encoded.
    public static func makeKey() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64EncodedString()
    }

    public static func request(key: String, host: String = "localhost", path: String = "/") -> Data {
        let lines = [
            "GET \(path) HTTP/1.1",
            "Host: \(host)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    public static func acceptValue(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + acceptGUID).utf8))).base64EncodedString()
    }

    /// `head` is the response up to (not including) the blank line. True for `101` with the right accept value.
    public static func validate(head: Data, key: String) -> Bool {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        guard let status = lines.first?.split(separator: " ", maxSplits: 2), status.count >= 2,
              status[0].hasPrefix("HTTP/1."), status[1] == "101" else { return false }
        let expected = acceptValue(for: key)
        return lines.dropFirst().contains { line in
            guard let colon = line.firstIndex(of: ":") else { return false }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return name.caseInsensitiveCompare("Sec-WebSocket-Accept") == .orderedSame && value == expected
        }
    }
}
