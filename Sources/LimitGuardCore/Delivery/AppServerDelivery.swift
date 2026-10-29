import Foundation
import OSLog

/// What `thread/read` tells about a loaded thread.
public struct ThreadInfo: Equatable, Sendable {
    public var threadId: String
    public var cwd: String?
    /// `idle` | `active` | `systemError` | `notLoaded`; display only (eligibility comes from the rollout).
    public var statusType: String?
    public var ephemeral: Bool

    public init(threadId: String, cwd: String?, statusType: String?, ephemeral: Bool) {
        self.threadId = threadId
        self.cwd = cwd
        self.statusType = statusType
        self.ephemeral = ephemeral
    }
}

/// Continues a thread by starting a turn on the shared app-server daemon, which the Terminal TUI shows
/// like a typed message (spike S5). Uses its own client over `WebSocketTransport`, not the reads client.
public struct AppServerDelivery: ContinueDelivery {
    static let requestTimeout: Duration = .seconds(15)
    /// Upper bound on `thread/loaded/list` pages, against a server that never ends the list.
    static let maxLoadedPages = 50

    private static let logger = Logger(subsystem: "com.cybokron.limitguard", category: "Delivery")

    private let client: AppServerClient

    public init(client: AppServerClient) {
        self.client = client
    }

    /// A client for the shared daemon via `codex app-server proxy`.
    public static func makeProxyClient(codexExecutable: URL, clientName: String, clientVersion: String) -> AppServerClient {
        AppServerClient(
            transportFactory: { WebSocketTransport.codexProxy(executable: codexExecutable) },
            clientName: clientName, clientVersion: clientVersion)
    }

    public func deliver(_ request: ContinueRequest) async -> DeliveryResult {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refused("empty continue text")
        }
        let loaded: [String]
        do {
            loaded = try await loadedThreadIds()
        } catch {
            return .failed("thread/loaded/list: \(Self.describe(error))")
        }
        guard loaded.contains(request.threadId) else { return .refused("thread not loaded") }

        // Exactly these keys: no model / effort / approval / sandbox overrides (D27).
        let params: [String: Any] = [
            "threadId": request.threadId,
            "input": [["type": "text", "text": request.text]],
            "clientUserMessageId": request.clientMessageId.uuidString.lowercased(),
        ]
        do {
            _ = try await client.request("turn/start", params: params, timeout: Self.requestTimeout)
            return .sent
        } catch AppServerError.timeout {
            // The server may still have started the turn.
            return .failed("turn/start timed out; delivery unknown")
        } catch {
            return .failed("turn/start: \(Self.describe(error))")
        }
    }

    /// Ids of the threads loaded in the daemon (by TUI clients and others), all pages, without duplicates.
    public func loadedThreadIds() async throws -> [String] {
        var ids: [String] = []
        var seen: Set<String> = []
        var cursor: String?
        var usedCursors: Set<String> = []
        for page in 0..<Self.maxLoadedPages {
            if page == Self.maxLoadedPages - 1 {
                Self.logger.notice("thread/loaded/list: reading the last of \(Self.maxLoadedPages) pages; later pages are ignored")
            }
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let data = try await client.request("thread/loaded/list", params: params, timeout: Self.requestTimeout)
            let object = try JSONField.object(from: data)
            guard let page = object["data"] as? [Any] else {
                throw ProtocolDecodingError(message: "thread/loaded/list: missing data")
            }
            for case let id as String in page where seen.insert(id).inserted { ids.append(id) }
            guard let next = JSONField.string(object["nextCursor"]), usedCursors.insert(next).inserted else { break }
            cursor = next
        }
        return ids
    }

    public func readThread(_ threadId: String) async throws -> ThreadInfo {
        let params: [String: Any] = ["threadId": threadId, "includeTurns": false]
        let data = try await client.request("thread/read", params: params, timeout: Self.requestTimeout)
        guard let thread = try JSONField.object(from: data)["thread"] as? [String: Any] else {
            throw ProtocolDecodingError(message: "thread/read: missing thread")
        }
        return ThreadInfo(
            threadId: JSONField.string(thread["id"]) ?? threadId,
            cwd: JSONField.string(thread["cwd"]),
            statusType: JSONField.string((thread["status"] as? [String: Any])?["type"]),
            ephemeral: JSONField.bool(thread["ephemeral"]) ?? false)
    }

    /// threadId → cwd of every loaded, non-ephemeral thread that `thread/read` describes. A thread that
    /// cannot be read is left out; a failing list throws.
    public func loadedThreadCwds() async throws -> [String: String] {
        var cwds: [String: String] = [:]
        for id in try await loadedThreadIds() {
            guard let info = try? await readThread(id), !info.ephemeral, let cwd = info.cwd, !cwd.isEmpty else { continue }
            cwds[id] = cwd
        }
        return cwds
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case AppServerError.timeout: return "timeout"
        case AppServerError.transportExited(let status): return "transport exited (\(status))"
        case AppServerError.rpcError(let code, let message): return "rpc error \(code): \(message)"
        case AppServerError.notStarted: return "not started"
        case AppServerError.invalidParams: return "invalid params"
        case let decoding as ProtocolDecodingError: return decoding.message
        default: return String(describing: error)
        }
    }
}
