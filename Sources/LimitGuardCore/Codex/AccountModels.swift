import Foundation

public struct RateLimitWindow: Equatable, Sendable {
    public var usedPercent: Double
    public var windowMinutes: Int?
    public var resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    init?(json: Any?) {
        guard let dict = json as? [String: Any], let used = JSONField.double(dict["usedPercent"]) else { return nil }
        self.init(
            usedPercent: used,
            windowMinutes: JSONField.int(dict["windowDurationMins"]),
            resetsAt: JSONField.date(dict["resetsAt"])
        )
    }
}

public enum ResetCreditStatus: Equatable, Sendable {
    case available, redeeming, redeemed
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "available": self = .available
        case "redeeming": self = .redeeming
        case "redeemed": self = .redeemed
        default: self = .unknown(rawValue)
        }
    }
}

public struct ResetCredit: Equatable, Sendable, Identifiable {
    public var id: String
    public var status: ResetCreditStatus
    public var grantedAt: Date
    public var expiresAt: Date?
    public var title: String?
    public var detail: String?

    public init(id: String, status: ResetCreditStatus, grantedAt: Date, expiresAt: Date?, title: String?, detail: String?) {
        self.id = id
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.title = title
        self.detail = detail
    }

    /// Nil when `id`, `status` or `grantedAt` is missing: such a credit is never offered for spending.
    init?(json: Any?) {
        guard let dict = json as? [String: Any],
              let id = JSONField.string(dict["id"]), !id.isEmpty,
              let status = JSONField.string(dict["status"]),
              let grantedAt = JSONField.date(dict["grantedAt"])
        else { return nil }
        self.init(
            id: id,
            status: ResetCreditStatus(rawValue: status),
            grantedAt: grantedAt,
            expiresAt: JSONField.date(dict["expiresAt"]),
            title: JSONField.string(dict["title"]),
            detail: JSONField.string(dict["description"])
        )
    }
}

public struct AccountSnapshot: Equatable, Sendable {
    public var ordinaryUsageAllowed: Bool?
    public var fiveHour: RateLimitWindow?
    public var weekly: RateLimitWindow?
    public var planType: String?
    public var reachedType: String?
    public var accountId: String?
    /// Earliest `expiresAt` first, credits that never expire last.
    public var credits: [ResetCredit]
    public var availableCreditCount: Int
    public var readAt: Date

    public init(
        ordinaryUsageAllowed: Bool?, fiveHour: RateLimitWindow?, weekly: RateLimitWindow?,
        planType: String?, reachedType: String?, accountId: String?,
        credits: [ResetCredit], availableCreditCount: Int, readAt: Date
    ) {
        self.ordinaryUsageAllowed = ordinaryUsageAllowed
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.planType = planType
        self.reachedType = reachedType
        self.accountId = accountId
        self.credits = credits
        self.availableCreditCount = availableCreditCount
        self.readAt = readAt
    }

    /// Decodes the `result` object of `account/rateLimits/read`.
    public static func decode(from json: Data, readAt: Date) throws -> (AccountSnapshot, ProtocolHealth) {
        let root = try JSONField.object(from: json)
        var problems: [String] = []

        let allowed = JSONField.bool(root["ordinaryUsageAllowed"])
        if allowed == nil { problems.append("ordinaryUsageAllowed missing") }

        let limits = root["rateLimits"] as? [String: Any]
        if limits == nil { problems.append("rateLimits missing") }

        var credits: [ResetCredit] = []
        var availableCount: Int?
        if let summary = root["rateLimitResetCredits"] as? [String: Any] {
            availableCount = JSONField.int(summary["availableCount"])
            for raw in summary["credits"] as? [Any] ?? [] {
                if let credit = ResetCredit(json: raw) {
                    credits.append(credit)
                } else {
                    problems.append("reset credit without id/status")
                }
            }
        }
        credits = sortedByExpiry(credits)

        let snapshot = AccountSnapshot(
            ordinaryUsageAllowed: allowed,
            fiveHour: RateLimitWindow(json: limits?["primary"]),
            weekly: RateLimitWindow(json: limits?["secondary"]),
            planType: JSONField.string(limits?["planType"]),
            reachedType: JSONField.string(limits?["rateLimitReachedType"]),
            accountId: JSONField.string(root["accountId"]),
            credits: credits,
            availableCreditCount: availableCount ?? credits.filter { $0.status == .available }.count,
            readAt: readAt
        )
        let health: ProtocolHealth = problems.isEmpty ? .full : .readOnly(reason: problems.joined(separator: "; "))
        return (snapshot, health)
    }

    private static func sortedByExpiry(_ credits: [ResetCredit]) -> [ResetCredit] {
        // Stable: enumerate to keep server order among equal expiries.
        credits.enumerated().sorted { lhs, rhs in
            switch (lhs.element.expiresAt, rhs.element.expiresAt) {
            case let (a?, b?): return a != b ? a < b : lhs.offset < rhs.offset
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

public struct DailyUsage: Equatable, Sendable {
    public var day: String
    public var tokens: Int64

    public init(day: String, tokens: Int64) {
        self.day = day
        self.tokens = tokens
    }
}

public struct UsageReport: Equatable, Sendable {
    public var daily: [DailyUsage]?
    public var peakDailyTokens: Int64?
    public var currentStreakDays: Int?

    public init(daily: [DailyUsage]?, peakDailyTokens: Int64?, currentStreakDays: Int?) {
        self.daily = daily
        self.peakDailyTokens = peakDailyTokens
        self.currentStreakDays = currentStreakDays
    }

    /// Decodes the `result` object of `account/usage/read`.
    public static func decode(from json: Data) throws -> UsageReport {
        let root = try JSONField.object(from: json)
        let summary = root["summary"] as? [String: Any]
        let daily = (root["dailyUsageBuckets"] as? [Any])?.compactMap { raw -> DailyUsage? in
            guard let dict = raw as? [String: Any],
                  let day = JSONField.string(dict["startDate"]),
                  let tokens = JSONField.int64(dict["tokens"])
            else { return nil }
            return DailyUsage(day: day, tokens: tokens)
        }
        return UsageReport(
            daily: daily,
            peakDailyTokens: JSONField.int64(summary?["peakDailyTokens"]),
            currentStreakDays: JSONField.int(summary?["currentStreakDays"])
        )
    }
}

public enum ConsumeOutcome: Equatable, Sendable {
    case reset, nothingToReset, noCredit, alreadyRedeemed

    /// Decodes the `result` object of `account/rateLimitResetCredit/consume`; nil for an unknown outcome.
    public static func decode(from json: Data) -> ConsumeOutcome? {
        guard let root = try? JSONField.object(from: json), let raw = JSONField.string(root["outcome"]) else { return nil }
        switch raw {
        case "reset": return .reset
        case "nothingToReset": return .nothingToReset
        case "noCredit": return .noCredit
        case "alreadyRedeemed": return .alreadyRedeemed
        default: return nil
        }
    }
}
