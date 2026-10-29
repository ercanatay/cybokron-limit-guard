import Foundation

/// The rollout lines the app cares about. A rollout (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`)
/// is one JSON object per line: `{"timestamp", "type", "payload": {…}}`; everything not listed here
/// decodes to `.other`.
public enum RolloutEvent: Equatable {
    /// The file's first line (`type: session_meta`). Forked rollouts repeat the parent's meta later
    /// in the file; only the first line describes the thread itself.
    case sessionMeta(id: String, cwd: String, originator: String?, cliVersion: String?)
    /// `event_msg` / `task_started`.
    case taskStarted(turnId: String, at: Date)
    /// `event_msg` / `task_complete`. `errorInfo` is `error.codex_error_info`, nil when the turn
    /// finished (`error` absent or null), "unknown" when an error carries no info.
    case taskComplete(turnId: String, at: Date, errorInfo: String?)
    /// `response_item` / `message` with `role: user` (includes injected boilerplate). `clientMessageId`
    /// comes from the matching `event_msg` / `item_completed` `UserMessage` item's `client_id`.
    case userMessage(text: String, at: Date, clientMessageId: String?)
    /// `event_msg` / `turn_aborted` (e.g. `reason: interrupted`).
    case turnAborted(at: Date)
    case other

    var date: Date? {
        switch self {
        case let .taskStarted(_, at), let .taskComplete(_, at, _), let .userMessage(_, at, _), let .turnAborted(at):
            return at
        case .sessionMeta, .other:
            return nil
        }
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSecondFormatter = ISO8601DateFormatter()

    static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return fractionalFormatter.date(from: string) ?? wholeSecondFormatter.date(from: string)
    }

    /// One decoded line: an event, or the `UserMessage` item that repeats the user message before it.
    enum Line: Equatable {
        case event(RolloutEvent)
        case userItem(text: String, at: Date, clientMessageId: String?)
    }

    /// Decodes one line. `isFirstLine` allows `session_meta`; returns nil for lines that are not JSON
    /// objects (e.g. a line still being written).
    static func decode(line: Data, isFirstLine: Bool) -> Line? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        let payload = object["payload"] as? [String: Any] ?? [:]
        let at = parseDate(object["timestamp"])

        switch object["type"] as? String {
        case "session_meta":
            guard isFirstLine, let id = payload["id"] as? String else { return .event(.other) }
            return .event(.sessionMeta(
                id: id, cwd: payload["cwd"] as? String ?? "",
                originator: payload["originator"] as? String, cliVersion: payload["cli_version"] as? String
            ))
        case "event_msg":
            return decodeEventMessage(payload, at: at)
        case "response_item":
            guard let at, payload["type"] as? String == "message", payload["role"] as? String == "user" else {
                return .event(.other)
            }
            let content = payload["content"] as? [[String: Any]] ?? []
            return .event(.userMessage(text: joinedText(content, itemType: "input_text"), at: at, clientMessageId: nil))
        default:
            return .event(.other)
        }
    }

    private static func decodeEventMessage(_ payload: [String: Any], at: Date?) -> Line {
        guard let at else { return .event(.other) }
        switch payload["type"] as? String {
        case "task_started":
            guard let turnId = payload["turn_id"] as? String else { return .event(.other) }
            return .event(.taskStarted(turnId: turnId, at: at))
        case "task_complete":
            guard let turnId = payload["turn_id"] as? String else { return .event(.other) }
            return .event(.taskComplete(turnId: turnId, at: at, errorInfo: errorInfo(payload["error"])))
        case "turn_aborted":
            return .event(.turnAborted(at: at))
        case "item_completed":
            guard let item = payload["item"] as? [String: Any], item["type"] as? String == "UserMessage" else {
                return .event(.other)
            }
            let content = item["content"] as? [[String: Any]] ?? []
            return .userItem(
                text: joinedText(content, itemType: "text"), at: at, clientMessageId: item["client_id"] as? String
            )
        default:
            return .event(.other)
        }
    }

    private static func errorInfo(_ error: Any?) -> String? {
        guard let error, !(error is NSNull) else { return nil }
        let info = (error as? [String: Any])?["codex_error_info"]
        if let info = info as? String { return info }
        // Some error kinds are objects keyed by their name, e.g. {"http_connection_failed": {…}}.
        if let info = info as? [String: Any], let name = info.keys.sorted().first { return name }
        return "unknown"
    }

    private static func joinedText(_ content: [[String: Any]], itemType: String) -> String {
        content.filter { $0["type"] as? String == itemType }.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
