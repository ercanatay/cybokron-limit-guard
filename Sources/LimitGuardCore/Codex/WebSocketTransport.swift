import Foundation

/// A raw byte stream to a peer (a child process's stdin/stdout, or a test double).
public protocol ByteChannel: AnyObject, Sendable {
    /// Called with each chunk as it arrives, in order, on an arbitrary thread.
    var onData: (@Sendable (Data) -> Void)? { get set }
    /// Called once with the termination status when the peer goes away on its own. Not called after `stop()`.
    var onExit: (@Sendable (Int32) -> Void)? { get set }
    func start() throws
    /// Queues the bytes and returns without blocking; must not call back into `onData` synchronously.
    func write(_ data: Data) throws
    func stop()
}

/// Runs `executable arguments…` and passes raw bytes through its stdin/stdout.
public final class ProcessByteChannel: ByteChannel, @unchecked Sendable {
    private let executable: URL
    private let arguments: [String]
    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var stopped = false
    /// Writes never run on the caller's thread: a full pipe must not block the caller.
    private let writeQueue = DispatchQueue(label: "limitguard.byte-channel.writer")
    private var _onData: (@Sendable (Data) -> Void)?
    private var _onExit: (@Sendable (Int32) -> Void)?

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    public var onData: (@Sendable (Data) -> Void)? {
        get { lock.withLock { _onData } }
        set { lock.withLock { _onData = newValue } }
    }

    public var onExit: (@Sendable (Int32) -> Void)? {
        get { lock.withLock { _onExit } }
        set { lock.withLock { _onExit = newValue } }
    }

    public func start() throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try lock.withLock {
            guard self.process == nil else { throw TransportError.alreadyStarted }
            // A write to a dead child must surface as an error, not kill the app.
            signal(SIGPIPE, SIG_IGN)
            try process.run()
            self.process = process
            self.stdin = input.fileHandleForWriting
        }
        let reader = output.fileHandleForReading
        let thread = Thread { [weak self] in
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                self?.onData?(chunk)
            }
            process.waitUntilExit()
            guard let self else { return }
            let (wasStopped, callback) = self.lock.withLock { (self.stopped, self._onExit) }
            if !wasStopped { callback?(process.terminationStatus) }
        }
        thread.name = "limitguard.byte-channel.reader"
        thread.start()
    }

    /// A failed write terminates the child, which the reader thread then reports through `onExit`.
    public func write(_ data: Data) throws {
        guard lock.withLock({ !stopped && stdin != nil }) else { throw TransportError.notRunning }
        writeQueue.async { [weak self] in
            guard let self else { return }
            let (handle, process) = self.lock.withLock { () -> (FileHandle?, Process?) in
                (self.stopped ? nil : self.stdin, self.process)
            }
            guard let handle else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                if let process, process.isRunning { process.terminate() }
            }
        }
    }

    public func stop() {
        let (process, stdin) = lock.withLock { () -> (Process?, FileHandle?) in
            stopped = true
            return (self.process, self.stdin)
        }
        // Terminate first so a write blocked on a full pipe fails and frees the queue; close after it.
        if let process, process.isRunning { process.terminate() }
        writeQueue.async { try? stdin?.close() }
    }
}

/// JSON-RPC lines over a WebSocket on a byte channel — the shared Codex app-server daemon as reached
/// through `codex app-server proxy` (spike S5). Each sent line becomes one masked text frame; each
/// received text message is handed to `onLine` whole. Binary messages are ignored.
public final class WebSocketTransport: AppServerTransport, @unchecked Sendable {
    /// `onExit` status when the upgrade is refused or its accept value is wrong.
    public static let handshakeFailedStatus: Int32 = -2
    /// `onExit` status after the server sent a close frame.
    public static let closedByPeerStatus: Int32 = -3
    /// `onExit` status after the server broke the framing rules.
    public static let protocolErrorStatus: Int32 = -4
    /// The upgrade response must fit in this many bytes.
    static let maxHeadSize = 16 * 1024

    private enum Phase {
        case idle
        case upgrading
        case open
        case closed
    }

    private let channel: ByteChannel
    private let lock = NSLock()
    private var phase = Phase.idle
    private var key = ""
    private var head = Data()
    private var decoder = WebSocketDecoder()
    /// Frames sent before the upgrade completed, flushed in order once it has.
    private var held: [Data] = []
    private var stopped = false
    private var exitReported = false
    private var _onLine: (@Sendable (Data) -> Void)?
    private var _onExit: (@Sendable (Int32) -> Void)?

    public init(channel: ByteChannel) {
        self.channel = channel
    }

    /// The transport to the shared daemon: `codex app-server proxy`.
    public static func codexProxy(executable: URL) -> WebSocketTransport {
        WebSocketTransport(channel: ProcessByteChannel(executable: executable, arguments: ["app-server", "proxy"]))
    }

    public var onLine: (@Sendable (Data) -> Void)? {
        get { lock.withLock { _onLine } }
        set { lock.withLock { _onLine = newValue } }
    }

    public var onExit: (@Sendable (Int32) -> Void)? {
        get { lock.withLock { _onExit } }
        set { lock.withLock { _onExit = newValue } }
    }

    /// Starts the channel and writes the upgrade request; does not wait for the response.
    public func start() throws {
        let request: Data = try lock.withLock {
            guard phase == .idle else { throw TransportError.alreadyStarted }
            phase = .upgrading
            key = WebSocketHandshake.makeKey()
            return WebSocketHandshake.request(key: key)
        }
        channel.onData = { [weak self] in self?.receive($0) }
        channel.onExit = { [weak self] in self?.peerExited($0) }
        do {
            try channel.start()
            try channel.write(request)
        } catch {
            lock.withLock { phase = .closed }
            channel.stop()
            throw error
        }
    }

    public func send(_ line: Data) throws {
        var payload = line
        while let last = payload.last, last == 0x0A || last == 0x0D { payload.removeLast() }
        let frame = WebSocketFrame.encode(opcode: .text, payload: payload, maskKey: WebSocketFrame.randomMaskKey())
        try lock.withLock {
            guard !stopped else { throw TransportError.notRunning }
            switch phase {
            case .idle, .closed: throw TransportError.notRunning
            case .upgrading: held.append(frame)
            case .open: try channel.write(frame)
            }
        }
    }

    public func stop() {
        lock.withLock {
            stopped = true
            phase = .closed
            held.removeAll()
        }
        channel.stop()
    }

    // MARK: - Receiving

    private func receive(_ data: Data) {
        var lines: [Data] = []
        let failure: Int32? = lock.withLock {
            var bytes = data
            if phase == .upgrading {
                head.append(bytes)
                guard let end = head.range(of: Data("\r\n\r\n".utf8)) else {
                    return head.count > Self.maxHeadSize ? Self.handshakeFailedStatus : nil
                }
                guard WebSocketHandshake.validate(head: head[..<end.lowerBound], key: key) else {
                    return Self.handshakeFailedStatus
                }
                bytes = head[end.upperBound...]
                head = Data()
                phase = .open
                for frame in held { try? channel.write(frame) }
                held.removeAll()
            }
            guard phase == .open, !bytes.isEmpty else { return nil }
            do {
                for event in try decoder.feed(bytes) {
                    switch event {
                    case .text(let message): lines.append(message)
                    case .binary, .pong: break
                    case .ping(let payload):
                        try? channel.write(WebSocketFrame.encode(opcode: .pong, payload: payload, maskKey: WebSocketFrame.randomMaskKey()))
                    case .close(let code):
                        try? channel.write(WebSocketFrame.close(code: code ?? 1000, maskKey: WebSocketFrame.randomMaskKey()))
                        return Self.closedByPeerStatus
                    }
                }
            } catch {
                return Self.protocolErrorStatus
            }
            return nil
        }
        let callback = onLine
        for line in lines { callback?(line) }
        if let failure { fail(failure) }
    }

    private func peerExited(_ status: Int32) {
        guard let callback = claimExit() else { return }
        callback(status)
    }

    /// Ends the connection from our side and reports `status` as the exit.
    private func fail(_ status: Int32) {
        let callback = claimExit()
        // Best effort: the echoed close frame may not reach the proxy before it is terminated.
        channel.stop()
        callback?(status)
    }

    /// The exit callback, at most once, and never after `stop()`.
    private func claimExit() -> (@Sendable (Int32) -> Void)? {
        lock.withLock {
            guard !stopped, !exitReported else { return nil }
            exitReported = true
            phase = .closed
            held.removeAll()
            return _onExit
        }
    }
}
