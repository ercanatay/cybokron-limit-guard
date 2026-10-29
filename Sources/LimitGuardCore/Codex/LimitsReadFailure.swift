import Foundation

/// Why the last `account/rateLimits/read` failed, as the popover's status line tells it (spec §4.4).
public enum LimitsReadFailure: Equatable, Sendable {
    /// Codex answered but is not signed in with ChatGPT (`codex login`).
    case notSignedIn
    /// The app-server did not start, exited or did not answer in time; tried again on the next poll.
    case unreachable
    case other(String)

    static let authMarkers = ["auth", "login", "sign in", "unauthorized", "401"]

    public static func classify(_ error: Error) -> LimitsReadFailure {
        switch error {
        case let AppServerError.rpcError(code, message):
            let text = message.lowercased()
            if code == 401 || authMarkers.contains(where: text.contains) { return .notSignedIn }
            return .other(AppServerDelivery.describe(error))
        case AppServerError.timeout, AppServerError.transportExited, AppServerError.notStarted:
            return .unreachable
        default:
            return .other(AppServerDelivery.describe(error))
        }
    }
}
