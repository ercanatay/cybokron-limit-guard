import Foundation
import Testing
@testable import LimitGuardCore

@Suite("ChartData")
struct ChartDataTests {
    private func report(_ days: [(String, Int64)]) -> UsageReport {
        UsageReport(daily: days.map { DailyUsage(day: $0.0, tokens: $0.1) }, peakDailyTokens: nil, currentStreakDays: nil)
    }

    @Test func fillsMissingDays() {
        let r = report([("2026-10-27", 100), ("2026-10-29", 300)])
        let out = ChartData.daily(r, days: 4, today: "2026-10-29")
        #expect(out.map(\.day) == ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29"])
        #expect(out.map(\.tokens) == [0, 100, 0, 300])
    }

    @Test func clipsToRange() {
        let r = report([("2026-10-01", 5), ("2026-10-28", 7), ("2026-10-29", 9), ("2026-10-30", 11)])
        let out = ChartData.daily(r, days: 7, today: "2026-10-29")
        #expect(out.count == 7)
        #expect(out.first?.day == "2026-10-23")
        #expect(out.last?.day == "2026-10-29")
        #expect(out.map(\.tokens).reduce(0, +) == 16)
    }

    @Test func monthBoundaryAndNoBuckets() {
        let out = ChartData.daily(report([]), days: 3, today: "2026-03-01")
        #expect(out.map(\.day) == ["2026-02-27", "2026-02-28", "2026-03-01"])
        #expect(ChartData.daily(UsageReport(daily: nil, peakDailyTokens: nil, currentStreakDays: nil), days: 3, today: "2026-03-01").isEmpty)
        #expect(ChartData.daily(report([]), days: 3, today: "garbage").isEmpty)
    }

    @Test func limitHistoryClipsToDays() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let samples = [
            UsageSample(date: now.addingTimeInterval(-9 * 86400), fiveHour: 1, weekly: 1),
            UsageSample(date: now.addingTimeInterval(-3 * 86400), fiveHour: 2, weekly: 2),
            UsageSample(date: now, fiveHour: 3, weekly: 3),
        ]
        #expect(ChartData.limitHistory(samples, days: 7).map(\.fiveHour) == [2, 3])
        #expect(ChartData.limitHistory(samples, days: 90).count == 3)
        #expect(ChartData.limitHistory([], days: 7).isEmpty)
    }

    @Test func compactTokens() {
        #expect(ChartData.compactTokens(0) == "0")
        #expect(ChartData.compactTokens(950) == "950")
        #expect(ChartData.compactTokens(1_500) == "1.5 K")
        #expect(ChartData.compactTokens(248_000_000) == "248 M")
        #expect(ChartData.compactTokens(1_200_000_000) == "1.2 B")
        #expect(ChartData.compactTokens(3_000_000) == "3 M")
    }
}
