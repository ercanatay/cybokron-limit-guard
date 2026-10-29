import Foundation

/// A bidirectional newline-delimited channel to a `codex app-server` process (or a test double).
public protocol AppServerTransport: AnyObject, Sendable {
    /// Called once per complete line (without the trailing newline), on an arbitrary thread.
    var onLine: (@Sendable (Data) -> Void)? { get set }
    /// Called once with the termination status when the peer goes away on its own. Not called after `stop()`.
    var onExit: (@Sendable (Int32) -> Void)? { get set }
    func start() throws
    func send(_ line: Data) throws
    func stop()
}

public enum TransportError: Error, Equatable, Sendable {
    case notRunning
    case alreadyStarted
}

/// Runs `executable arguments…` and speaks newline-delimited JSON over its stdin/stdout.
public final class ProcessTransport: AppServerTransport, @unchecked Sendable {
    private let executable: URL
    private let arguments: [String]
    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var stopped = false
    private var _onLine: (@Sendable (Data) -> Void)?
    private var _onExit: (@Sendable (Int32) -> Void)?

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    public var onLine: (@Sendable (Data) -> Void)? {
        get { lock.withLock { _onLine } }
        set { lock.withLock { _onLine = newValue } }
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
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if !line.isEmpty { self?.onLine?(line) }
                }
            }
            process.waitUntilExit()
            guard let self else { return }
            let (wasStopped, callback) = self.lock.withLock { (self.stopped, self._onExit) }
            if !wasStopped { callback?(process.terminationStatus) }
        }
        thread.name = "limitguard.app-server.reader"
        thread.start()
    }

    public func send(_ line: Data) throws {
        guard let handle = lock.withLock({ stopped ? nil : stdin }) else { throw TransportError.notRunning }
        var payload = line
        if payload.last != 0x0A { payload.append(0x0A) }
        try handle.write(contentsOf: payload)
    }

    public func stop() {
        let (process, stdin) = lock.withLock { () -> (Process?, FileHandle?) in
            stopped = true
            return (self.process, self.stdin)
        }
        try? stdin?.close()
        if let process, process.isRunning { process.terminate() }
    }
}
