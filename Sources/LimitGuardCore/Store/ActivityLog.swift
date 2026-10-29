import Foundation

public enum ActivityKind: String, Codable, Equatable, CaseIterable {
    case limitReached, limitIsBack, continueScheduled, continueSent, continueCancelled
    case continueSkipped, unconfirmed, loopGuardStop, runawayStop, resetUsed, resetExpiring
    case readOnly, permissionDenied, error

    /// Unknown values (from a newer app version) decode to `.error` instead of failing the file.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ActivityKind(rawValue: raw) ?? .error
    }
}

public struct ActivityEntry: Codable, Equatable {
    public var date: Date
    public var kind: ActivityKind
    public var threadId: String?
    public var tab: String?
    public var text: String?
    public var detail: String?
    public var codexVersion: String?

    public init(date: Date, kind: ActivityKind, threadId: String? = nil, tab: String? = nil,
                text: String? = nil, detail: String? = nil, codexVersion: String? = nil) {
        self.date = date
        self.kind = kind
        self.threadId = threadId
        self.tab = tab
        self.text = text
        self.detail = detail
        self.codexVersion = codexVersion
    }
}

struct ActivityFile: Codable, Equatable {
    var entries: [ActivityEntry] = []

    init(entries: [ActivityEntry] = []) { self.entries = entries }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([ActivityEntry].self, forKey: .entries) ?? []
    }
}

/// `activity.json`: the newest 100 entries, oldest first.
public struct ActivityLog {
    public static let limit = 100
    private let store: JSONStore<ActivityFile>

    public init(url: URL) {
        store = JSONStore(url: url, schemaVersion: 1)
    }

    public func entries() throws -> [ActivityEntry] {
        try store.load()?.entries ?? []
    }

    public func append(_ entry: ActivityEntry) throws {
        var all = try entries()
        all.append(entry)
        if all.count > Self.limit { all.removeFirst(all.count - Self.limit) }
        try store.save(ActivityFile(entries: all))
    }

    public func clear() throws {
        try store.save(ActivityFile())
    }
}
