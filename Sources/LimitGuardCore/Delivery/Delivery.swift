import Foundation

/// One continue message for one thread. `clientMessageId` is the idempotency handle: a retry after an
/// unknown outcome must reuse it (and check `DeliveryConfirmer` first), never mint a new one.
public struct ContinueRequest: Equatable, Sendable {
    public var threadId: String
    public var text: String
    public var clientMessageId: UUID
    /// The Terminal tab the thread was matched to, for display and logging only.
    public var tab: TabRef?

    public init(threadId: String, text: String, clientMessageId: UUID, tab: TabRef?) {
        self.threadId = threadId
        self.text = text
        self.clientMessageId = clientMessageId
        self.tab = tab
    }
}

public enum DeliveryResult: Equatable, Sendable {
    /// The server accepted the turn; confirm it later through the rollout.
    case sent
    /// Nothing was sent: the request is not safe to deliver now.
    case refused(String)
    /// Sending failed or its outcome is unknown; confirm before any retry.
    case failed(String)
}

public protocol ContinueDelivery: Sendable {
    func deliver(_ request: ContinueRequest) async -> DeliveryResult
}

public enum DeliveryConfirmer {
    /// True once the thread's rollout records a user message with our `clientUserMessageId`
    /// (spike S5: the rollout's `client_id` equals it exactly).
    public static func isConfirmed(request: ContinueRequest, session: SessionState) -> Bool {
        guard session.threadId == request.threadId else { return false }
        let id = request.clientMessageId.uuidString.lowercased()
        return session.seenClientMessageIds.contains { $0.lowercased() == id }
    }
}
