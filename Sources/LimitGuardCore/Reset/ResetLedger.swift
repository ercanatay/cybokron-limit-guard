import Foundation

public enum SpendReason: String, Codable, Equatable, Sendable {
    case auto, manual
}

/// One consume call in flight (spec §8.3). Written before the call so a crash or timeout is retried
/// with the same `idempotencyKey` and `creditId`.
public struct LedgerEntry: Codable, Equatable, Sendable {
    public var idempotencyKey: UUID
    public var creditId: String
    public var reason: SpendReason
    public var createdAt: Date
    /// Consume calls sent with this entry so far.
    public var attempts: Int

    public init(idempotencyKey: UUID, creditId: String, reason: SpendReason, createdAt: Date, attempts: Int) {
        self.idempotencyKey = idempotencyKey
        self.creditId = creditId
        self.reason = reason
        self.createdAt = createdAt
        self.attempts = attempts
    }
}

/// `reset-ledger.json`. `JSONStore` needs an object at the top level, so the entries are wrapped.
public struct LedgerFile: Codable, Equatable {
    public var entries: [LedgerEntry] = []

    public init(entries: [LedgerEntry] = []) { self.entries = entries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([LedgerEntry].self, forKey: .entries) ?? []
    }
}

public enum LedgerError: Error, Equatable {
    /// An entry without an outcome exists; it must be resumed or expire before a new spend.
    case entryPending
    case unknownEntry
}

/// Holds at most one pending consume. Every change is saved before it returns.
public actor ResetLedger {
    private let store: JSONStore<LedgerFile>
    private var file: LedgerFile?

    public init(store: JSONStore<LedgerFile>) {
        self.store = store
    }

    /// Writes a new entry; throws `.entryPending` while another entry exists.
    public func begin(creditId: String, reason: SpendReason, now: Date) throws -> LedgerEntry {
        var current = try loaded()
        guard current.entries.isEmpty else { throw LedgerError.entryPending }
        let entry = LedgerEntry(idempotencyKey: UUID(), creditId: creditId, reason: reason, createdAt: now, attempts: 0)
        current.entries.append(entry)
        try save(current)
        return entry
    }

    /// The oldest entry without an outcome. An unreadable file reads as nothing pending.
    public func pending() -> LedgerEntry? {
        (try? loaded())?.entries.first
    }

    /// Counts one more consume call for the entry; saved before the call is sent.
    func recordAttempt(_ key: UUID) throws -> LedgerEntry {
        var current = try loaded()
        guard let index = current.entries.firstIndex(where: { $0.idempotencyKey == key }) else {
            throw LedgerError.unknownEntry
        }
        current.entries[index].attempts += 1
        try save(current)
        return current.entries[index]
    }

    public func finish(_ key: UUID) throws {
        var current = try loaded()
        current.entries.removeAll { $0.idempotencyKey == key }
        try save(current)
    }

    /// Removes and returns entries created more than `age` ago (spec §8.3 step 4: "unknown result").
    public func expireOlderThan(_ age: TimeInterval, now: Date) throws -> [LedgerEntry] {
        var current = try loaded()
        let expired = current.entries.filter { now.timeIntervalSince($0.createdAt) > age }
        guard !expired.isEmpty else { return [] }
        current.entries.removeAll { now.timeIntervalSince($0.createdAt) > age }
        try save(current)
        return expired
    }

    private func loaded() throws -> LedgerFile {
        if let file { return file }
        let value = try store.load() ?? LedgerFile()
        file = value
        return value
    }

    private func save(_ value: LedgerFile) throws {
        try store.save(value)
        file = value
    }
}
