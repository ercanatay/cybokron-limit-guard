import Foundation
import Testing
@testable import LimitGuardCore

@Suite("Settings limits")
struct SettingsLimitsTests {
    @Test func clampKeepsValuesInRange() {
        #expect(SettingsLimits.clamp(-5, to: SettingsLimits.countdownSeconds) == 0)
        #expect(SettingsLimits.clamp(61, to: SettingsLimits.countdownSeconds) == 60)
        #expect(SettingsLimits.clamp(10, to: SettingsLimits.countdownSeconds) == 10)
        #expect(SettingsLimits.clamp(0, to: SettingsLimits.maxContinues) == 1)
        #expect(SettingsLimits.clamp(11, to: SettingsLimits.maxContinues) == 10)
        #expect(SettingsLimits.clamp(79, to: SettingsLimits.autoSpendThreshold) == 80)
        #expect(SettingsLimits.clamp(100, to: SettingsLimits.autoSpendThreshold) == 99)
    }

    @Test func defaultsAreAlreadyInRange() {
        #expect(Settings().clamped() == Settings())
    }

    @Test func clampedFixesOutOfRangeFields() {
        var s = Settings()
        s.countdownSeconds = 500
        s.maxContinues = 0
        s.minGapSeconds = 5
        s.autoSpendThreshold = 100
        s.fallbackText = "   "
        s.codexPathOverride = "  "
        let c = s.clamped()
        #expect(c.countdownSeconds == 60)
        #expect(c.maxContinues == 1)
        #expect(c.minGapSeconds == 60)
        #expect(c.autoSpendThreshold == 99)
        #expect(c.fallbackText == "continue")
        #expect(c.codexPathOverride == nil)
    }

    @Test func minGapMinutesRoundTripsAndClamps() {
        var s = Settings()
        #expect(s.minGapMinutes == 2)
        s.minGapMinutes = 5
        #expect(s.minGapSeconds == 300)
        s.minGapMinutes = 0
        #expect(s.minGapSeconds == 60)
        s.minGapMinutes = 999
        #expect(s.minGapSeconds == 3600)
    }

    @Test func languageMapsToAppleLanguages() {
        #expect(AppLanguage.system.appleLanguages == nil)
        #expect(AppLanguage.english.appleLanguages == ["en"])
        #expect(AppLanguage.turkish.appleLanguages == ["tr"])
    }

    @Test func continueCodesAreNormalised() {
        #expect(ContinueTextTable.normalizedCode(" TR ") == "tr")
        #expect(ContinueTextTable.normalizedCode("pt-BR") == "pt")
        #expect(ContinueTextTable.normalizedCode("") == nil)
        #expect(ContinueTextTable.normalizedCode("x") == nil)
        #expect(ContinueTextTable.normalizedCode("12") == nil)
        #expect(ContinueTextTable.normalizedCode("english") == nil)
    }
}
