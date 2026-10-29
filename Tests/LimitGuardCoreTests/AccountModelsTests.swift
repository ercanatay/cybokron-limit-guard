import Foundation
import Testing
@testable import LimitGuardCore

@Suite("AccountModels")
struct AccountModelsTests {
    private let readAt = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func decodesLiveSnapshot() throws {
        let (snapshot, health) = try AccountSnapshot.decode(from: fixture("rate-limits-live.json"), readAt: readAt)
        #expect(snapshot.ordinaryUsageAllowed == false)
        #expect(snapshot.fiveHour?.usedPercent == 100)
        #expect(snapshot.fiveHour?.windowMinutes == 300)
        #expect(snapshot.weekly?.usedPercent == 59)
        #expect(snapshot.weekly?.windowMinutes == 10080)
        #expect(snapshot.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1793286502))
        #expect(snapshot.planType == "team")
        #expect(snapshot.reachedType == "workspace_owner_credits_depleted")
        #expect(snapshot.accountId == "acct-test")
        #expect(snapshot.readAt == readAt)
        #expect(snapshot.credits.count == 2)
        #expect(snapshot.availableCreditCount == 2)
        #expect(snapshot.credits[0].id == "RateLimitResetCredit_3509ea3582e88191b472658ffebbe55f")
        #expect(snapshot.credits[0].status == .available)
        #expect(snapshot.credits[0].grantedAt == Date(timeIntervalSince1970: 1790710182))
        #expect(snapshot.credits[0].expiresAt == Date(timeIntervalSince1970: 1793302182))
        #expect(snapshot.credits[0].title == "Full reset (Weekly + 5 hr)")
        #expect(health == .full)
    }

    @Test func missingOrdinaryUsageAllowedIsReadOnly() throws {
        let (snapshot, health) = try AccountSnapshot.decode(from: fixture("rate-limits-missing-gate.json"), readAt: readAt)
        #expect(snapshot.ordinaryUsageAllowed == nil)
        #expect(snapshot.fiveHour?.usedPercent == 100)
        #expect(snapshot.weekly?.usedPercent == 59)
        guard case .readOnly = health else {
            Issue.record("expected readOnly, got \(health)")
            return
        }
    }

    @Test func unknownCreditStatusDecodesAsUnknown() throws {
        let (snapshot, health) = try AccountSnapshot.decode(from: fixture("rate-limits-unknown-enum.json"), readAt: readAt)
        #expect(snapshot.credits.contains { $0.status == .unknown("frozen") })
        #expect(snapshot.availableCreditCount == 2)
        #expect(snapshot.availableCredits.count == 1)
        #expect(health == .full)
    }

    @Test func creditsSortByExpiryNilLast() throws {
        let json = """
        {"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":1},"secondary":{"usedPercent":2}},"rateLimitResetCredits":{"availableCount":3,"credits":[
        {"id":"a","status":"available","grantedAt":1,"expiresAt":null},
        {"id":"b","status":"available","grantedAt":1,"expiresAt":300},
        {"id":"c","status":"available","grantedAt":1,"expiresAt":200}]}}
        """
        let (snapshot, _) = try AccountSnapshot.decode(from: Data(json.utf8), readAt: readAt)
        #expect(snapshot.credits.map(\.id) == ["c", "b", "a"])
    }

    @Test func creditWithoutIdIsReadOnly() throws {
        let json = """
        {"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":1},"secondary":{"usedPercent":2}},"rateLimitResetCredits":{"availableCount":1,"credits":[
        {"status":"available","grantedAt":1,"expiresAt":null}]}}
        """
        let (snapshot, health) = try AccountSnapshot.decode(from: Data(json.utf8), readAt: readAt)
        #expect(snapshot.credits.isEmpty)
        guard case .readOnly = health else {
            Issue.record("expected readOnly, got \(health)")
            return
        }
    }

    @Test func missingWindowsAreReadOnly() throws {
        let (snapshot, health) = try AccountSnapshot.decode(
            from: Data(#"{"ordinaryUsageAllowed":true,"rateLimits":{}}"#.utf8), readAt: readAt)
        #expect(snapshot.fiveHour == nil)
        guard case .readOnly = health else {
            Issue.record("expected readOnly, got \(health)")
            return
        }
    }

    @Test func stringUsedPercentIsReadOnly() throws {
        let json = #"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":"100"},"secondary":{"usedPercent":2}}}"#
        let (snapshot, health) = try AccountSnapshot.decode(from: Data(json.utf8), readAt: readAt)
        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.weekly?.usedPercent == 2)
        guard case .readOnly = health else {
            Issue.record("expected readOnly, got \(health)")
            return
        }
    }

    @Test func missingRateLimitsIsReadOnly() throws {
        let (snapshot, health) = try AccountSnapshot.decode(from: Data(#"{"ordinaryUsageAllowed":true}"#.utf8), readAt: readAt)
        #expect(snapshot.fiveHour == nil)
        guard case .readOnly = health else {
            Issue.record("expected readOnly, got \(health)")
            return
        }
    }

    @Test func nonObjectResultThrows() {
        #expect(throws: (any Error).self) {
            _ = try AccountSnapshot.decode(from: Data("[1]".utf8), readAt: readAt)
        }
    }

    @Test func bigintFieldsDecode() throws {
        let report = try UsageReport.decode(from: fixture("usage-live.json"))
        #expect(report.daily?.count == 5)
        #expect(report.daily?.last?.tokens == 248173462)
        #expect(report.daily?.last?.day == "2026-10-28")
        #expect(report.peakDailyTokens == 248173462)
        #expect(report.currentStreakDays == 17)
    }

    @Test func consumeOutcomes() {
        func outcome(_ s: String) -> ConsumeOutcome? {
            ConsumeOutcome.decode(from: Data(#"{"outcome":"\#(s)"}"#.utf8))
        }
        #expect(outcome("reset") == .reset)
        #expect(outcome("nothingToReset") == .nothingToReset)
        #expect(outcome("noCredit") == .noCredit)
        #expect(outcome("alreadyRedeemed") == .alreadyRedeemed)
        #expect(outcome("weird") == nil)
        #expect(ConsumeOutcome.decode(from: Data("{}".utf8)) == nil)
    }
}
