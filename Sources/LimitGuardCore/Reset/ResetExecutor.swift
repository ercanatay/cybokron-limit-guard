import Foundation

public enum SpendResult: Equatable, Sendable {
    /// A final outcome; the ledger entry is cleared and the call is never repeated.
    case outcome(ConsumeOutcome)
    /// The result is not known. The caller stops automatic spending (read-only) for this window.
    case unknown
    /// Another spend is running or a ledger entry is pending; nothing was sent.
    case busy
}

/// Runs consume calls through the ledger (spec §8.3). The only code path that spends reset credits.
public actor ResetExecutor {
    public static let defaultConsumeTimeout: Duration = .seconds(30)
    /// Waits before the retries that follow the first call (~5 min in total).
    public static let retryDelays: [Duration] = [.seconds(10), .seconds(60), .seconds(240)]

    private let service: CodexAccountService
    private let ledger: ResetLedger
    private let now: @Sendable () -> Date
    private let consumeTimeout: Duration
    private let sleeper: @Sendable (Duration) async -> Void
    private let log: @Sendable (String) -> Void
    /// Set before the first suspension point so a re-entrant call cannot slip in between the
    /// pending check and the ledger write.
    private var inFlight = false

    public init(
        service: CodexAccountService, ledger: ResetLedger, now: @escaping @Sendable () -> Date,
        consumeTimeout: Duration = ResetExecutor.defaultConsumeTimeout,
        sleeper: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.service = service
        self.ledger = ledger
        self.now = now
        self.consumeTimeout = consumeTimeout
        self.sleeper = sleeper
        self.log = log
    }

    /// Spends `creditId` with a fresh ledger entry. `.busy` while another spend runs or an entry is pending.
    ///
    /// For `.auto`, the caller must first persist `ResetPolicy.marker(for:now:)` as `AppState.autoSpend`
    /// and keep it whatever the result: the marker, not the outcome, limits automatic spends to one per week.
    public func spend(creditId: String, reason: SpendReason) async -> SpendResult {
        guard !inFlight else { return .busy }
        inFlight = true
        defer { inFlight = false }
        do {
            if try await ledger.pending() != nil { return .busy }
        } catch {
            log("reset ledger unreadable, consume not sent: \(error)")
            return .unknown
        }
        let entry: LedgerEntry
        do {
            entry = try await ledger.begin(creditId: creditId, reason: reason, now: now())
        } catch LedgerError.entryPending {
            return .busy
        } catch {
            // Nothing was sent: without a written entry the call must not happen.
            log("reset ledger write failed, consume not sent: \(error)")
            return .unknown
        }
        return await run(entry)
    }

    /// Retries the pending ledger entry with its stored key and credit (on launch). Nil when none is
    /// pending; `.unknown` when the ledger cannot be read (an entry may exist that we cannot see).
    public func resumePending() async -> SpendResult? {
        guard !inFlight else { return .busy }
        inFlight = true
        defer { inFlight = false }
        let entry: LedgerEntry?
        do {
            entry = try await ledger.pending()
        } catch {
            log("reset ledger unreadable, pending consume not resumed: \(error)")
            return .unknown
        }
        guard let entry else { return nil }
        return await run(entry)
    }

    /// The first call plus up to `retryDelays.count` retries, all with the same entry.
    private func run(_ entry: LedgerEntry) async -> SpendResult {
        var retry = 0
        while true {
            do {
                _ = try await ledger.recordAttempt(entry.idempotencyKey)
            } catch {
                log("reset ledger attempt not saved, consume not sent: \(error)")
                return .unknown
            }
            do {
                let outcome = try await service.consume(
                    creditId: entry.creditId, idempotencyKey: entry.idempotencyKey, timeout: consumeTimeout)
                guard let outcome else {
                    // An outcome we do not know: the credit may be spent. Keep the entry; it expires after 24 h.
                    log("consume returned an unknown outcome for credit \(entry.creditId)")
                    return .unknown
                }
                await finish(entry)
                return .outcome(outcome)
            } catch AppServerError.timeout, AppServerError.transportExited, AppServerError.notStarted {
                // The request may have reached the server: only the same key and credit may be sent again.
                guard retry < Self.retryDelays.count else {
                    log("consume gave no answer after \(retry + 1) tries; entry kept for the next launch")
                    return .unknown
                }
                await sleeper(Self.retryDelays[retry])
                retry += 1
                // App quitting: the entry stays and the next launch resumes it.
                if Task.isCancelled { return .unknown }
            } catch let AppServerError.rpcError(code, message) {
                // The server answered with an error, so this key produced no spend we could miss: clear the
                // entry. The caller still goes read-only for automatic spending in this window.
                log("consume failed with RPC error \(code): \(message)")
                await finish(entry)
                return .unknown
            } catch {
                // Anything else (cancellation, invalid params): keep the entry, a retry with the same key is safe.
                log("consume failed: \(error); entry kept")
                return .unknown
            }
        }
    }

    private func finish(_ entry: LedgerEntry) async {
        do {
            try await ledger.finish(entry.idempotencyKey)
        } catch {
            // The entry stays; a later resume repeats the key, which the server treats as the same call.
            log("reset ledger entry not cleared: \(error)")
        }
    }
}
