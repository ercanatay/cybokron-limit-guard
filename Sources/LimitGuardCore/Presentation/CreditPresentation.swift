import Foundation

/// One reset credit as a row of the popover's "Usage limit resets" section (spec §4.2).
public struct CreditRow: Equatable, Sendable, Identifiable {
    public enum ExpiryDay: Equatable, Sendable {
        case today, tomorrow
    }

    public var id: String
    /// The backend's title, shown as it is sent (never translated).
    public var title: String?
    public var detail: String?
    public var status: ResetCreditStatus
    /// Only an available credit gets a "Use Reset" button.
    public var canUse: Bool
    public var expiresAt: Date?
    /// The expiry date and time in the locale and time zone, e.g. "29 Oct 22:29"; nil when it never expires.
    public var expiryText: String?
    /// "GMT+3", "GMT", "GMT+5:30"; nil when it never expires.
    public var timeZoneLabel: String?
    /// Expires within 24 h: sorted first and tinted.
    public var isExpiringSoon: Bool
    /// For a credit expiring soon: whether that is today or tomorrow in the time zone.
    public var expiryDay: ExpiryDay?
}

public enum CreditPresentation {
    static let soonInterval: TimeInterval = 24 * 3600

    /// Credits expiring within 24 h first, each group by expiry (never-expiring last), otherwise in
    /// the order given.
    public static func rows(credits: [ResetCredit], now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> [CreditRow] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = expiryFormatter(locale: locale, timeZone: timeZone)

        let rows = credits.map { credit -> CreditRow in
            let left = credit.expiresAt.map { $0.timeIntervalSince(now) }
            let soon = left.map { $0 > 0 && $0 < soonInterval } ?? false
            var day: CreditRow.ExpiryDay?
            if soon, let expires = credit.expiresAt {
                day = calendar.isDate(expires, inSameDayAs: now) ? .today : .tomorrow
            }
            return CreditRow(
                id: credit.id, title: credit.title, detail: credit.detail, status: credit.status,
                canUse: credit.status == .available, expiresAt: credit.expiresAt,
                expiryText: credit.expiresAt.map { formatter.string(from: $0) },
                timeZoneLabel: credit.expiresAt.map { gmtLabel(for: timeZone, at: $0) },
                isExpiringSoon: soon, expiryDay: day)
        }
        let order = { (row: CreditRow) in row.expiresAt ?? .distantFuture }
        let soon = rows.filter(\.isExpiringSoon)
        let rest = rows.filter { !$0.isExpiringSoon }
        return stableSorted(soon, by: order) + stableSorted(rest, by: order)
    }

    /// Whether `creditId` can still be spent in `snapshot`: checked again after the confirmation alert,
    /// since the credit may have been used or have expired while the alert was open.
    public static func stillAvailable(creditId: String, in snapshot: AccountSnapshot?) -> Bool {
        snapshot?.credits.contains { $0.id == creditId && $0.status == .available } ?? false
    }

    /// The offset from GMT at `date` (summer time included): "GMT+3", "GMT-4", "GMT+5:30", "GMT".
    public static func gmtLabel(for timeZone: TimeZone, at date: Date) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        guard seconds != 0 else { return "GMT" }
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "GMT\(sign)\(hours)" : "GMT\(sign)\(hours):\(String(format: "%02d", rest))"
    }

    private static let formatterLock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    /// One formatter per locale and time zone. `DateFormatter` is thread-safe for formatting; the
    /// lock guards the cache.
    static func expiryFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let key = "\(locale.identifier)|\(timeZone.identifier)"
        return formatterLock.withLock {
            if let cached = formatters[key] { return cached }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate("dMMMHHmm")
            formatters[key] = formatter
            return formatter
        }
    }

    private static func stableSorted(_ rows: [CreditRow], by key: (CreditRow) -> Date) -> [CreditRow] {
        rows.enumerated()
            .sorted { key($0.element) != key($1.element) ? key($0.element) < key($1.element) : $0.offset < $1.offset }
            .map(\.element)
    }
}
