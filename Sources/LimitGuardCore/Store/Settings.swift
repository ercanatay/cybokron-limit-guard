import Foundation

public enum AppLanguage: String, Codable, Equatable, CaseIterable {
    case system, english, turkish

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AppLanguage(rawValue: raw) ?? .system
    }
}

public struct NotificationToggles: Codable, Equatable {
    public var limitReached = true
    public var limitIsBack = true
    public var continueSent = true
    public var continueSkipped = true
    public var resetUsed = true
    public var resetExpiring = true
    public var readOnly = true
    public var permissionMissing = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationToggles()
        limitReached = try c.decodeIfPresent(Bool.self, forKey: .limitReached) ?? d.limitReached
        limitIsBack = try c.decodeIfPresent(Bool.self, forKey: .limitIsBack) ?? d.limitIsBack
        continueSent = try c.decodeIfPresent(Bool.self, forKey: .continueSent) ?? d.continueSent
        continueSkipped = try c.decodeIfPresent(Bool.self, forKey: .continueSkipped) ?? d.continueSkipped
        resetUsed = try c.decodeIfPresent(Bool.self, forKey: .resetUsed) ?? d.resetUsed
        resetExpiring = try c.decodeIfPresent(Bool.self, forKey: .resetExpiring) ?? d.resetExpiring
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? d.readOnly
        permissionMissing = try c.decodeIfPresent(Bool.self, forKey: .permissionMissing) ?? d.permissionMissing
    }
}

public struct Settings: Codable, Equatable {
    public var noticeAcceptedVersion: Int?
    public var noticeAcceptedAt: Date?
    public var autoContinue = true
    public var countdownSeconds = 10
    public var maxContinues = 3
    public var minGapSeconds = 120
    public var autoSpendEnabled = false
    public var autoSpendThreshold = 97
    public var expiryReminders = true
    public var keepAwake = true
    public var showPercentInMenuBar = true
    public var launchAtLogin = true
    public var guardNewTabsAutomatically = false
    public var codexPathOverride: String?
    public var language: AppLanguage = .system
    public var continueTexts: [String: String] = ["tr": "devam et", "en": "continue"]
    public var fallbackText = "continue"
    public var notify = NotificationToggles()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        noticeAcceptedVersion = try c.decodeIfPresent(Int.self, forKey: .noticeAcceptedVersion)
        noticeAcceptedAt = try c.decodeIfPresent(Date.self, forKey: .noticeAcceptedAt)
        autoContinue = try c.decodeIfPresent(Bool.self, forKey: .autoContinue) ?? d.autoContinue
        countdownSeconds = try c.decodeIfPresent(Int.self, forKey: .countdownSeconds) ?? d.countdownSeconds
        maxContinues = try c.decodeIfPresent(Int.self, forKey: .maxContinues) ?? d.maxContinues
        minGapSeconds = try c.decodeIfPresent(Int.self, forKey: .minGapSeconds) ?? d.minGapSeconds
        autoSpendEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoSpendEnabled) ?? d.autoSpendEnabled
        autoSpendThreshold = try c.decodeIfPresent(Int.self, forKey: .autoSpendThreshold) ?? d.autoSpendThreshold
        expiryReminders = try c.decodeIfPresent(Bool.self, forKey: .expiryReminders) ?? d.expiryReminders
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? d.keepAwake
        showPercentInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showPercentInMenuBar) ?? d.showPercentInMenuBar
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        guardNewTabsAutomatically = try c.decodeIfPresent(Bool.self, forKey: .guardNewTabsAutomatically) ?? d.guardNewTabsAutomatically
        codexPathOverride = try c.decodeIfPresent(String.self, forKey: .codexPathOverride)
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? d.language
        continueTexts = try c.decodeIfPresent([String: String].self, forKey: .continueTexts) ?? d.continueTexts
        fallbackText = try c.decodeIfPresent(String.self, forKey: .fallbackText) ?? d.fallbackText
        notify = try c.decodeIfPresent(NotificationToggles.self, forKey: .notify) ?? d.notify
    }
}
