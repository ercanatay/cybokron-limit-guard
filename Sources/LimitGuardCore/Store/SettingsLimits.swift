import Foundation

/// The ranges the Settings window allows (spec §10) and the pure rules around them.
public enum SettingsLimits {
    public static let countdownSeconds = 0...60
    public static let maxContinues = 1...10
    public static let minGapMinutes = 1...60
    public static let autoSpendThreshold = 50...99

    public static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

extension Settings {
    /// The minimum gap between two continues, in whole minutes (stored as seconds).
    public var minGapMinutes: Int {
        get { (minGapSeconds + 30) / 60 }
        set { minGapSeconds = SettingsLimits.clamp(newValue, to: SettingsLimits.minGapMinutes) * 60 }
    }

    /// A copy with every numeric value inside its range and no empty fallback text or Codex path.
    public func clamped() -> Settings {
        var result = self
        result.countdownSeconds = SettingsLimits.clamp(countdownSeconds, to: SettingsLimits.countdownSeconds)
        result.maxContinues = SettingsLimits.clamp(maxContinues, to: SettingsLimits.maxContinues)
        let gap = SettingsLimits.minGapMinutes
        result.minGapSeconds = SettingsLimits.clamp(minGapSeconds, to: gap.lowerBound * 60...gap.upperBound * 60)
        result.autoSpendThreshold = SettingsLimits.clamp(autoSpendThreshold, to: SettingsLimits.autoSpendThreshold)
        if fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.fallbackText = Settings().fallbackText
        }
        if let path = codexPathOverride, path.trimmingCharacters(in: .whitespaces).isEmpty {
            result.codexPathOverride = nil
        }
        return result
    }
}

extension AppLanguage {
    /// The value for the app's own `AppleLanguages` default; nil means "follow the system" (the key
    /// is removed).
    public var appleLanguages: [String]? {
        switch self {
        case .system: nil
        case .english: ["en"]
        case .turkish: ["tr"]
        }
    }
}

/// A row of the language → continue text table.
public enum ContinueTextTable {
    /// The table key for what the user typed: trimmed, lower-cased, a region dropped ("pt-BR" → "pt");
    /// nil when nothing usable is left or it isn't letters.
    public static func normalizedCode(_ input: String) -> String? {
        let base = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        guard (2...3).contains(base.count), base.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return base
    }
}

extension SettingsLimits {
    /// Applies edited continue text for `code`: trimmed; an empty result or a row that was removed
    /// meanwhile leaves the table as it was. Returns the text the table now holds (nil: no row).
    @discardableResult
    public static func applyContinueText(_ text: String, for code: String, to table: inout [String: String]) -> String? {
        guard let previous = table[code] else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return previous }
        table[code] = trimmed
        return trimmed
    }

    /// The fallback text after an edit: trimmed, the previous one when nothing is left.
    public static func appliedFallbackText(_ text: String, previous: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? previous : trimmed
    }
}
