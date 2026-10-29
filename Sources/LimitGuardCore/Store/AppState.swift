import Foundation

/// A tab is the Codex TUI process on a tty: `pid` and `startTime` are part of its identity, so a guard
/// (or an untick) never carries over to another process that later gets the same tty or pid.
public struct TabRef: Codable, Hashable, Sendable {
    public var windowId: Int
    public var tabIndex: Int
    public var tty: String
    /// The Codex TUI's pid; nil only in files written before guards were bound to the process.
    public var pid: Int32?
    /// The process start time exactly as `ps -o lstart=` prints it; compared, never parsed.
    public var startTime: String?

    public init(windowId: Int, tabIndex: Int, tty: String, pid: Int32? = nil, startTime: String? = nil) {
        self.windowId = windowId
        self.tabIndex = tabIndex
        self.tty = tty
        self.pid = pid
        self.startTime = startTime
    }
}

public struct GuardedTab: Codable, Equatable {
    public var ref: TabRef
    public var addedAt: Date

    public init(ref: TabRef, addedAt: Date) {
        self.ref = ref
        self.addedAt = addedAt
    }
}

public struct ScheduledContinue: Codable, Equatable {
    public var threadId: String
    public var text: String
    public var fireAt: Date

    public init(threadId: String, text: String, fireAt: Date) {
        self.threadId = threadId
        self.text = text
        self.fireAt = fireAt
    }
}

public struct PendingDelivery: Codable, Equatable {
    public var threadId: String
    public var clientMessageId: UUID
    public var text: String
    public var sentAt: Date

    public init(threadId: String, clientMessageId: UUID, text: String, sentAt: Date) {
        self.threadId = threadId
        self.clientMessageId = clientMessageId
        self.text = text
        self.sentAt = sentAt
    }
}

public struct LoopRecord: Codable, Equatable {
    public var consecutive = 0
    public var lastSentAt: Date?
    public var shortTurnsInARow = 0

    public init(consecutive: Int = 0, lastSentAt: Date? = nil, shortTurnsInARow: Int = 0) {
        self.consecutive = consecutive
        self.lastSentAt = lastSentAt
        self.shortTurnsInARow = shortTurnsInARow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        consecutive = try c.decodeIfPresent(Int.self, forKey: .consecutive) ?? 0
        lastSentAt = try c.decodeIfPresent(Date.self, forKey: .lastSentAt)
        shortTurnsInARow = try c.decodeIfPresent(Int.self, forKey: .shortTurnsInARow) ?? 0
    }
}

/// The last automatic reset-credit spend. Written before the consume call and kept whatever the outcome.
public struct AutoSpendMarker: Codable, Equatable, Sendable {
    public var accountId: String
    public var spentAt: Date

    public init(accountId: String, spentAt: Date) {
        self.accountId = accountId
        self.spentAt = spentAt
    }
}

public struct AppState: Codable, Equatable {
    /// Keyed by thread id.
    public var loop: [String: LoopRecord] = [:]
    /// Blocks a second automatic spend for the same account within 7 days.
    public var autoSpend: AutoSpendMarker?
    public var scheduled: ScheduledContinue?
    public var pendingDeliveries: [PendingDelivery] = []
    public var guardedTabs: [GuardedTab] = []
    public var expiryNotified: Set<String> = []
    /// Keyed by thread id: how the current usage-limit stop was classified when first seen.
    public var stops: [String: StopInfo] = [:]
    /// Keyed by thread id: the turn id of a stop that is never continued automatically again
    /// (continue sent, cancelled, skipped or stopped by the loop guard). Cleared when the stop is superseded.
    public var settledStops: [String: String] = [:]
    /// Tabs the owner unticked; never guarded automatically while the tab lives.
    public var untickedTabs: [TabRef] = []
    /// Pause (automatic continues and spends) survives a relaunch.
    public var paused = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        loop = try c.decodeIfPresent([String: LoopRecord].self, forKey: .loop) ?? [:]
        autoSpend = try c.decodeIfPresent(AutoSpendMarker.self, forKey: .autoSpend)
        scheduled = try c.decodeIfPresent(ScheduledContinue.self, forKey: .scheduled)
        pendingDeliveries = try c.decodeIfPresent([PendingDelivery].self, forKey: .pendingDeliveries) ?? []
        guardedTabs = try c.decodeIfPresent([GuardedTab].self, forKey: .guardedTabs) ?? []
        expiryNotified = try c.decodeIfPresent(Set<String>.self, forKey: .expiryNotified) ?? []
        stops = try c.decodeIfPresent([String: StopInfo].self, forKey: .stops) ?? [:]
        settledStops = try c.decodeIfPresent([String: String].self, forKey: .settledStops) ?? [:]
        untickedTabs = try c.decodeIfPresent([TabRef].self, forKey: .untickedTabs) ?? []
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    }
}
