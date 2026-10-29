import Foundation
import Testing
@testable import LimitGuardCore

@Suite("Forecast")
struct ForecastTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func at(_ hoursAgo: Double) -> Date { now.addingTimeInterval(-hoursAgo * 3600) }

    @Test func linearBurnProjects() throws {
        let samples: [(Date, Double)] = [(at(3), 50), (at(2), 52), (at(1), 54), (at(0), 56)]
        let run = try #require(Forecast.runOut(samples: samples, now: now, resetsAt: nil))
        #expect(abs(run.timeIntervalSince(now) - 22 * 3600) < 60)
    }

    @Test func tooFewSamplesNil() {
        #expect(Forecast.runOut(samples: [(at(3), 50), (at(0), 56)], now: now, resetsAt: nil) == nil)
        // Three samples but spanning under 2 h.
        #expect(Forecast.runOut(samples: [(at(1), 50), (at(0.5), 52), (at(0), 54)], now: now, resetsAt: nil) == nil)
    }

    @Test func flatNil() {
        let samples: [(Date, Double)] = [(at(3), 50), (at(2), 50), (at(1), 50), (at(0), 50)]
        #expect(Forecast.runOut(samples: samples, now: now, resetsAt: nil) == nil)
    }

    @Test func afterResetUsesOnlyNewSamples() throws {
        // 90 -> 95 then a reset to 2, then 2 -> 8 over 3 h (2 points/hour).
        let samples: [(Date, Double)] = [
            (at(5), 90), (at(4.5), 95), (at(3), 2), (at(2), 4), (at(1), 6), (at(0), 8),
        ]
        let run = try #require(Forecast.runOut(samples: samples, now: now, resetsAt: nil))
        #expect(abs(run.timeIntervalSince(now) - 46 * 3600) < 60)
    }

    @Test func beyondResetsAtNil() {
        let samples: [(Date, Double)] = [(at(3), 50), (at(2), 52), (at(1), 54), (at(0), 56)]
        #expect(Forecast.runOut(samples: samples, now: now, resetsAt: now.addingTimeInterval(10 * 3600)) == nil)
        #expect(Forecast.runOut(samples: samples, now: now, resetsAt: now.addingTimeInterval(23 * 3600)) != nil)
    }
}
