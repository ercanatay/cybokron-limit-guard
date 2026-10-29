import Foundation
@testable import LimitGuardCore

/// In-memory stand-in for `codex app-server`: scripted replies per method, records everything it receives.
final class FakeAppServer: AppServerTransport, @unchecked Sendable {
    enum Reply {
        case result(String)
        case error(code: Int, message: String)
        case drop
    }

    struct Script {
        var reply: Reply
        var delay: Duration
    }

    struct Request: Equatable {
        var id: Int
        var method: String
        var params: [String: String]
    }

    private let lock = NSLock()
    private var _onLine: (@Sendable (Data) -> Void)?
    private var _onExit: (@Sendable (Int32) -> Void)?
    private var scripts: [String: Script] = [:]
    private var _sentLines: [String] = []
    private var _requests: [Request] = []
    private var _started = false
    private var _stopped = false

    var onLine: (@Sendable (Data) -> Void)? {
        get { lock.withLock { _onLine } }
        set { lock.withLock { _onLine = newValue } }
    }

    var onExit: (@Sendable (Int32) -> Void)? {
        get { lock.withLock { _onExit } }
        set { lock.withLock { _onExit = newValue } }
    }

    // MARK: Scripting

    func script(_ method: String, result: String = "{}", delay: Duration = .zero) {
        lock.withLock { scripts[method] = Script(reply: .result(result), delay: delay) }
    }

    func scriptError(_ method: String, code: Int, message: String) {
        lock.withLock { scripts[method] = Script(reply: .error(code: code, message: message), delay: .zero) }
    }

    func scriptDrop(_ method: String) {
        lock.withLock { scripts[method] = Script(reply: .drop, delay: .zero) }
    }

    func simulateExit(_ status: Int32) {
        onExit?(status)
    }

    func emit(_ json: String) {
        onLine?(Data(json.utf8))
    }

    // MARK: Recording

    var sentLines: [String] { lock.withLock { _sentLines } }
    var requests: [Request] { lock.withLock { _requests } }
    var wasStarted: Bool { lock.withLock { _started } }
    var wasStopped: Bool { lock.withLock { _stopped } }

    // MARK: AppServerTransport

    func start() throws { lock.withLock { _started = true } }

    func stop() { lock.withLock { _stopped = true } }

    func send(_ line: Data) throws {
        let text = String(decoding: line, as: UTF8.self)
        lock.withLock { _sentLines.append(text) }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let method = object["method"] as? String,
              let id = object["id"] as? Int else { return }
        let params = (object["params"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        let script: Script = lock.withLock {
            _requests.append(Request(id: id, method: method, params: params))
            return scripts[method] ?? Script(
                reply: method == "initialize" ? .result("{}") : .error(code: -32601, message: "no script for \(method)"),
                delay: .zero)
        }
        let payload: String
        switch script.reply {
        case .drop: return
        case .result(let json): payload = #"{"id":\#(id),"result":\#(json)}"#
        case .error(let code, let message):
            payload = #"{"id":\#(id),"error":{"code":\#(code),"message":"\#(message)"}}"#
        }
        let seconds = Double(script.delay.components.seconds) + Double(script.delay.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.onLine?(Data(payload.utf8))
        }
    }
}

/// Hands out pre-built fakes in order and counts how many transports the client asked for.
final class FakeFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [FakeAppServer]
    private(set) var created: [FakeAppServer] = []

    init(_ fakes: [FakeAppServer]) { queue = fakes }

    func make() -> AppServerTransport {
        lock.withLock {
            let next = queue.isEmpty ? FakeAppServer() : queue.removeFirst()
            created.append(next)
            return next
        }
    }
}
