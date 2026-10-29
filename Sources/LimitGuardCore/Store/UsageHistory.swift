import Foundation

public struct UsageSample: Codable, Equatable {
    public var date: Date
    public var fiveHour: Double?
    public var weekly: Double?

    public init(date: Date, fiveHour: Double?, weekly: Double?) {
        self.date = date
        self.fiveHour = fiveHour
        self.weekly = weekly
    }
}

struct UsageHistoryFile: Codable, Equatable {
    var samples: [UsageSample] = []

    init(samples: [UsageSample] = []) { self.samples = samples }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        samples = try c.decodeIfPresent([UsageSample].self, forKey: .samples) ?? []
    }
}

/// `usage-history.json`: at most one sample per minute, kept for 30 days.
public struct UsageHistory {
    public static let minInterval: TimeInterval = 60
    public static let retention: TimeInterval = 30 * 24 * 3600
    private let store: JSONStore<UsageHistoryFile>

    public init(url: URL) {
        store = JSONStore(url: url, schemaVersion: 1)
    }

    public func samples() throws -> [UsageSample] {
        try store.load()?.samples ?? []
    }

    /// Returns false when the sample was dropped by the 1/min throttle.
    @discardableResult
    public func append(sample: UsageSample) throws -> Bool {
        var all = try samples()
        if let last = all.last, sample.date.timeIntervalSince(last.date) < Self.minInterval { return false }
        all.append(sample)
        let cutoff = sample.date.addingTimeInterval(-Self.retention)
        all.removeAll { $0.date < cutoff }
        try store.save(UsageHistoryFile(samples: all))
        return true
    }
}
