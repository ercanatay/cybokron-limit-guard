import Foundation

public enum AppServerError: Error, Equatable, Sendable {
    case timeout
    case transportExited(Int32)
    case rpcError(code: Int, message: String)
    case notStarted
}

/// JSON-RPC client for `codex app-server`: lazily starts the transport, performs `initialize`/`initialized`
/// once per transport, matches responses by `id` and restarts the transport after it exits (with back-off).
public actor AppServerClient {
    private enum Event {
        case line(Data)
        case exit(Int32)
    }

    private let transportFactory: @Sendable () -> AppServerTransport
    private let clientName: String
    private let clientVersion: String
    private let backoff: [Duration]

    private var transport: AppServerTransport?
    private var pump: Task<Void, Never>?
    private var handshake: Task<Void, Error>?
    private var handshaken = false
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var nextId = 1
    private var consecutiveFailures = 0
    private var notBefore: ContinuousClock.Instant?
    private var lastExitStatus: Int32 = -1
    private var isShutDown = false

    public init(
        transportFactory: @escaping @Sendable () -> AppServerTransport,
        clientName: String,
        clientVersion: String,
        backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(30)]
    ) {
        self.transportFactory = transportFactory
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.backoff = backoff.isEmpty ? [.zero] : backoff
    }

    /// True while a transport is running (it may not have completed the handshake yet).
    public var isConnected: Bool { transport != nil }

    /// Sends one request and returns the raw JSON of its `result`.
    /// `timeout` covers everything: waiting out a restart back-off, the handshake and the reply.
    public func request(_ method: String, params: [String: Any]? = nil, timeout: Duration) async throws -> Data {
        let deadline = ContinuousClock.now + timeout
        try await ensureTransport(deadline: deadline)
        try await ensureHandshake(deadline: deadline)
        return try await call(method, params: params, deadline: deadline)
    }

    /// Stops the transport and fails everything in flight; later requests throw `.notStarted`.
    public func shutdown() {
        isShutDown = true
        let current = transport
        tearDown(failWith: .notStarted)
        current?.stop()
    }

    // MARK: - Transport lifecycle

    private func ensureTransport(deadline: ContinuousClock.Instant) async throws {
        guard !isShutDown else { throw AppServerError.notStarted }
        if transport != nil { return }
        if let notBefore {
            let wait = notBefore - ContinuousClock.now
            if wait > .zero {
                guard ContinuousClock.now + wait < deadline else { throw AppServerError.timeout }
                try await Task.sleep(for: wait)
            }
        }
        // Another caller may have started (or shutdown may have run) while we slept.
        guard !isShutDown else { throw AppServerError.notStarted }
        if transport != nil { return }

        let fresh = transportFactory()
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        fresh.onLine = { continuation.yield(.line($0)) }
        fresh.onExit = { status in
            continuation.yield(.exit(status))
            continuation.finish()
        }
        do {
            try fresh.start()
        } catch {
            noteFailure()
            throw AppServerError.transportExited(-1)
        }
        transport = fresh
        nextId = 1
        handshaken = false
        pump = Task { [weak self] in
            for await event in stream {
                await self?.handle(event, from: fresh)
            }
        }
    }

    private func ensureHandshake(deadline: ContinuousClock.Instant) async throws {
        if handshaken { return }
        guard transport != nil else { throw AppServerError.transportExited(lastExitStatus) }
        let task: Task<Void, Error>
        if let existing = handshake {
            task = existing
        } else {
            task = Task { try await self.performHandshake(deadline: deadline) }
            handshake = task
        }
        try await task.value
    }

    private func performHandshake(deadline: ContinuousClock.Instant) async throws {
        let params: [String: Any] = [
            "clientInfo": ["name": clientName, "title": NSNull(), "version": clientVersion],
            "capabilities": NSNull(),
        ]
        do {
            _ = try await call("initialize", params: params, deadline: deadline)
            guard let current = transport else { throw AppServerError.transportExited(lastExitStatus) }
            try current.send(try Self.encode(["method": "initialized"]))
            handshaken = true
            consecutiveFailures = 0
            notBefore = nil
        } catch {
            handshake = nil
            if let rpc = error as? AppServerError, rpc == .timeout {
                // The server may still answer `initialize` later; a fresh transport is the only clean retry.
                let current = transport
                noteFailure()
                tearDown(failWith: .timeout)
                current?.stop()
            }
            throw error
        }
    }

    private func handle(_ event: Event, from source: AppServerTransport) {
        guard transport === source else { return }
        switch event {
        case .line(let data):
            handleLine(data)
        case .exit(let status):
            lastExitStatus = status
            noteFailure()
            tearDown(failWith: .transportExited(status))
        }
    }

    private func noteFailure() {
        consecutiveFailures += 1
        let delay = backoff[min(consecutiveFailures - 1, backoff.count - 1)]
        notBefore = ContinuousClock.now + delay
    }

    private func tearDown(failWith error: AppServerError) {
        transport = nil
        pump?.cancel()
        pump = nil
        handshake = nil
        handshaken = false
        let waiting = pending
        pending.removeAll()
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    // MARK: - Requests

    private func call(_ method: String, params: [String: Any]?, deadline: ContinuousClock.Instant) async throws -> Data {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { throw AppServerError.timeout }
        guard let current = transport else { throw AppServerError.transportExited(lastExitStatus) }
        let id = nextId
        nextId += 1
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        let line = try Self.encode(message)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: remaining)
                if !Task.isCancelled { await self?.complete(id, .failure(AppServerError.timeout)) }
            }
            do {
                try current.send(line)
            } catch {
                complete(id, .failure(AppServerError.transportExited(lastExitStatus)))
            }
        }
    }

    private func complete(_ id: Int, _ result: Result<Data, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func handleLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // Notifications and server-initiated requests carry `method`; neither is a response to us.
        guard object["method"] == nil, let id = JSONField.int(object["id"]) else { return }
        if let error = object["error"] as? [String: Any] {
            let code = JSONField.int(error["code"]) ?? 0
            let message = JSONField.string(error["message"]) ?? ""
            complete(id, .failure(AppServerError.rpcError(code: code, message: message)))
            return
        }
        let result = object["result"] ?? NSNull()
        if let raw = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
            complete(id, .success(raw))
        } else {
            complete(id, .failure(AppServerError.rpcError(code: 0, message: "unreadable result")))
        }
    }

    private static func encode(_ message: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
    }
}
