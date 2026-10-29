import Foundation

/// Typed wrapper over the account methods of `codex app-server`.
public actor CodexAccountService {
    private let client: AppServerClient
    private let now: @Sendable () -> Date

    static let readTimeout: Duration = .seconds(15)

    public init(client: AppServerClient, now: @escaping @Sendable () -> Date) {
        self.client = client
        self.now = now
    }

    /// Transport and RPC errors throw. An undecodable result degrades to an empty snapshot in read-only mode.
    public func readLimits() async throws -> (AccountSnapshot, ProtocolHealth) {
        let data = try await client.request("account/rateLimits/read", params: [:], timeout: Self.readTimeout)
        let readAt = now()
        do {
            return try AccountSnapshot.decode(from: data, readAt: readAt)
        } catch {
            let empty = AccountSnapshot(
                ordinaryUsageAllowed: nil, fiveHour: nil, weekly: nil,
                planType: nil, reachedType: nil, accountId: nil,
                credits: [], availableCreditCount: 0, readAt: readAt)
            return (empty, .readOnly(reason: "account/rateLimits/read result undecodable"))
        }
    }

    public func readUsage() async throws -> UsageReport {
        let data = try await client.request("account/usage/read", params: [:], timeout: Self.readTimeout)
        return try UsageReport.decode(from: data)
    }

    /// Spends one reset credit. Never retries: on `.timeout` / `.transportExited` the caller must retry
    /// with the same `idempotencyKey`. Nil means the server returned an outcome we do not know.
    public func consume(creditId: String, idempotencyKey: UUID, timeout: Duration) async throws -> ConsumeOutcome? {
        let params: [String: Any] = [
            "idempotencyKey": idempotencyKey.uuidString.lowercased(),
            "creditId": creditId,
        ]
        let data = try await client.request("account/rateLimitResetCredit/consume", params: params, timeout: timeout)
        return ConsumeOutcome.decode(from: data)
    }
}
