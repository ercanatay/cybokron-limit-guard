import Foundation
import Testing
@testable import LimitGuardCore

/// The popover's and the menu-bar item's pure formatting (spec §4.1, §4.2, §7.3).
@Suite("Presentation")
struct PresentationTests {
    private let now = Date(timeIntervalSince1970: 1_793_300_000)
    private let istanbul = TimeZone(identifier: "Europe/Istanbul")!

    private func snapshot(fiveHour: Double?, weekly: Double?, allowed: Bool? = true, credits: [ResetCredit] = []) -> AccountSnapshot {
        AccountSnapshot(
            ordinaryUsageAllowed: allowed,
            fiveHour: fiveHour.map { RateLimitWindow(usedPercent: $0, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600)) },
            weekly: weekly.map { RateLimitWindow(usedPercent: $0, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400)) },
            planType: "pro", reachedType: nil, accountId: "acc", credits: credits,
            availableCreditCount: credits.filter { $0.status == .available }.count, readAt: now)
    }

    private func credit(_ id: String, expiresIn seconds: TimeInterval?, status: ResetCreditStatus = .available) -> ResetCredit {
        ResetCredit(
            id: id, status: status, grantedAt: now.addingTimeInterval(-86_400),
            expiresAt: seconds.map { now.addingTimeInterval($0) }, title: "Full reset (Weekly + 5 hr)", detail: nil)
    }

    // MARK: - Menu-bar text

    @Test func menuBarShowsCriticalWindow() {
        let result = MenuBarText.make(snapshot: snapshot(fiveHour: 100, weekly: 59), showPercent: true)
        #expect(result.text == "5h 100%")
        #expect(result.level == .critical)
    }

    @Test func menuBarShowsWeeklyWhenItIsHigher() {
        let result = MenuBarText.make(snapshot: snapshot(fiveHour: 12, weekly: 97.4), showPercent: true)
        #expect(result.text == "W 97%")
        #expect(result.level == .critical)
    }

    @Test func menuBarLevels() {
        #expect(MenuBarText.make(snapshot: snapshot(fiveHour: 79.9, weekly: 10), showPercent: true).level == .normal)
        #expect(MenuBarText.make(snapshot: snapshot(fiveHour: 80, weekly: 10), showPercent: true).level == .warning)
        #expect(MenuBarText.make(snapshot: snapshot(fiveHour: 94.9, weekly: 10), showPercent: true).level == .warning)
        #expect(MenuBarText.make(snapshot: snapshot(fiveHour: 95, weekly: 10), showPercent: true).level == .critical)
    }

    /// The gate closed means no ordinary use, whatever the percentages say.
    @Test func menuBarCriticalWhenGateClosed() {
        let result = MenuBarText.make(snapshot: snapshot(fiveHour: 20, weekly: 30, allowed: false), showPercent: true)
        #expect(result.text == "W 30%")
        #expect(result.level == .critical)
    }

    /// Equal percentages show the 5-hour window, which resets sooner.
    @Test func menuBarTiePicksFiveHour() {
        #expect(MenuBarText.make(snapshot: snapshot(fiveHour: 50, weekly: 50), showPercent: true).text == "5h 50%")
    }

    @Test func menuBarHiddenWhenOff() {
        let result = MenuBarText.make(snapshot: snapshot(fiveHour: 100, weekly: 59), showPercent: false)
        #expect(result.text == nil)
        #expect(result.level == .critical)
    }

    @Test func menuBarWithoutSnapshot() {
        let result = MenuBarText.make(snapshot: nil, showPercent: true)
        #expect(result.text == nil)
        #expect(result.level == .normal)
        #expect(MenuBarText.make(snapshot: snapshot(fiveHour: nil, weekly: 41), showPercent: true).text == "W 41%")
        #expect(MenuBarText.make(snapshot: snapshot(fiveHour: nil, weekly: nil), showPercent: true).text == nil)
    }

    @Test func menuBarTextHasNoBrandLetters() {
        let text = MenuBarText.make(snapshot: snapshot(fiveHour: 100, weekly: 100), showPercent: true).text ?? ""
        #expect(!text.contains("LG"))
    }

    // MARK: - "resets in"

    /// The string tables of the repository, as a bundle with `en.lproj` and `tr.lproj`.
    private static let resources = Bundle(url: LocalizationTests.resources)!

    private func resetsIn(_ seconds: TimeInterval, _ language: String) -> String {
        Localization.$bundle.withValue(Self.resources) {
            ResetsInFormatter.string(until: now.addingTimeInterval(seconds), now: now, locale: Locale(identifier: language))
        }
    }

    @Test func resetsInFormats() throws {
        #expect(resetsIn(13_320, "en_US") == "3 h 42 m")
        #expect(resetsIn(5 * 86_400 + 21 * 3600 + 120, "en_US") == "5 d 21 h")
        #expect(resetsIn(42 * 60, "en_US") == "42 m")
        // A part of a minute counts as a whole one, so "0 m" never shows while time is left.
        #expect(resetsIn(41 * 60 + 1, "en_US") == "42 m")
        #expect(resetsIn(20, "en_US") == "1 m")
        #expect(resetsIn(0, "en_US") == "< 1 m")
        #expect(resetsIn(-300, "en_US") == "< 1 m")

        let tr = try LocalizationTests.table("tr")
        let hoursMinutes = try #require(tr["resetsIn.hoursMinutes"])
        #expect(resetsIn(13_320, "tr_TR") == String(format: hoursMinutes, 3, 42))
        #expect(resetsIn(13_320, "tr_TR") == "3 sa 42 dk")
        #expect(resetsIn(5 * 86_400 + 21 * 3600, "tr_TR") == "5 g 21 sa")
    }

    // MARK: - Reset credits

    @Test func expiringCreditFirst() {
        // Deliberately not sorted by expiry: the rows must sort themselves.
        let credits = [
            credit("later", expiresIn: 5 * 86_400),
            credit("never", expiresIn: nil),
            credit("soon", expiresIn: 6 * 3600),
            credit("sooner", expiresIn: 2 * 3600),
            credit("week", expiresIn: 2 * 86_400),
        ]
        let rows = CreditPresentation.rows(credits: credits, now: now, timeZone: istanbul, locale: Locale(identifier: "en_GB"))
        #expect(rows.map(\.id) == ["sooner", "soon", "week", "later", "never"])
        #expect(rows.map(\.isExpiringSoon) == [true, true, false, false, false])
        #expect(rows.last?.expiryText == nil)
        #expect(rows.last?.timeZoneLabel == nil)
    }

    @Test func creditRowsKeepTheBackendTitleAndOfferOnlyAvailableCredits() {
        let credits = [
            credit("a", expiresIn: 3 * 86_400),
            credit("b", expiresIn: 4 * 86_400, status: .redeemed),
            credit("c", expiresIn: 5 * 86_400, status: .redeeming),
            credit("d", expiresIn: 6 * 86_400, status: .unknown("frozen")),
        ]
        let rows = CreditPresentation.rows(credits: credits, now: now, timeZone: istanbul, locale: Locale(identifier: "tr_TR"))
        #expect(rows.map(\.canUse) == [true, false, false, false])
        #expect(rows.allSatisfy { $0.title == "Full reset (Weekly + 5 hr)" })
    }

    @Test func expiryDayIsTodayOrTomorrowInTheTimeZone() throws {
        // 2026-10-29 10:00 in Istanbul (UTC+3).
        let morning = try #require(ISO8601DateFormatter().date(from: "2026-10-29T07:00:00Z"))
        let today = ResetCredit(id: "t", status: .available, grantedAt: morning,
                                expiresAt: morning.addingTimeInterval(12 * 3600 + 29 * 60), title: nil, detail: nil)
        let tomorrow = ResetCredit(id: "m", status: .available, grantedAt: morning,
                                   expiresAt: morning.addingTimeInterval(20 * 3600), title: nil, detail: nil)
        let rows = CreditPresentation.rows(credits: [tomorrow, today], now: morning, timeZone: istanbul, locale: Locale(identifier: "en_GB"))
        #expect(rows.map(\.id) == ["t", "m"])
        #expect(rows.map(\.expiryDay) == [.today, .tomorrow])
        #expect(rows[0].timeZoneLabel == "GMT+3")
        // The date itself follows the locale; the day and the time are in it.
        let text = try #require(rows[0].expiryText)
        #expect(text.contains("29") && text.contains("Oct") && text.contains("22:29"))
    }

    @Test func gmtLabels() throws {
        #expect(CreditPresentation.gmtLabel(for: istanbul, at: now) == "GMT+3")
        #expect(CreditPresentation.gmtLabel(for: try #require(TimeZone(identifier: "UTC")), at: now) == "GMT")
        #expect(CreditPresentation.gmtLabel(for: try #require(TimeZone(identifier: "Asia/Kolkata")), at: now) == "GMT+5:30")
        #expect(CreditPresentation.gmtLabel(for: try #require(TimeZone(secondsFromGMT: -4 * 3600)), at: now) == "GMT-4")
        #expect(CreditPresentation.gmtLabel(for: try #require(TimeZone(secondsFromGMT: -(9 * 3600 + 30 * 60))), at: now) == "GMT-9:30")
    }

    // MARK: - Codex sessions

    private func tab(_ tty: String, cwd: String?) -> TerminalTab {
        TerminalTab(ref: TabRef(windowId: 0, tabIndex: 0, tty: tty), title: cwd.map { ($0 as NSString).lastPathComponent } ?? tty,
                    cwd: cwd, codexPid: 100, busy: false)
    }

    private func session(_ id: String, cwd: String, waiting: Bool) -> SessionState {
        SessionState(
            threadId: id, cwd: cwd, originator: TabMatcher.tuiOriginator,
            lastStop: waiting ? .usageLimit(at: now.addingTimeInterval(-600), turnId: "turn-\(id)") : .none,
            userActivityAfterStop: false, lastActivityAt: now.addingTimeInterval(-600), lastTurnDurations: [],
            languageSample: "", seenClientMessageIds: [])
    }

    @Test func sessionRowStates() {
        let tabs = [
            EngineTab(tab: tab("ttys001", cwd: "/Users/me/alpha"), isGuarded: true, threadId: "019a0000-aaaa", isWaiting: true),
            EngineTab(tab: tab("ttys002", cwd: "/Users/me/beta"), isGuarded: false, threadId: "019b0000-bbbb", isWaiting: true),
            EngineTab(tab: tab("ttys003", cwd: "/Users/me/gamma"), isGuarded: false, threadId: nil, isWaiting: false),
            EngineTab(tab: tab("ttys004", cwd: "/Users/me/gamma"), isGuarded: true, threadId: nil, isWaiting: false),
            EngineTab(tab: tab("ttys005", cwd: "/Users/me/delta"), isGuarded: false, threadId: nil, isWaiting: false),
        ]
        var titled = session("019a0000-aaaa", cwd: "/Users/me/alpha", waiting: true)
        titled.title = "Fix the parser"
        let sessions = [
            titled,
            session("019b0000-bbbb", cwd: "/Users/me/beta", waiting: true),
            // Waiting, but two tabs share its folder: the matcher left it out.
            session("019c0000-cccc", cwd: "/Users/me/gamma/", waiting: true),
            session("019d0000-dddd", cwd: "/Users/me/delta", waiting: false),
        ]
        let rows = SessionsPresentation.rows(tabs: tabs, sessions: sessions, snapshot: snapshot(fiveHour: 100, weekly: 40, allowed: false), now: now)
        #expect(rows.map(\.state) == [.waitingGuarded, .waitingNotGuarded, .ambiguous, .ambiguous, .idle])
        #expect(rows.map(\.isGuarded) == [true, false, false, true, false])
        #expect(rows[0].threadTitle == "Fix the parser")
        #expect(rows[1].threadTitle == nil)
        #expect(rows[0].title == "alpha")
        #expect(rows[0].tty == "ttys001")
        #expect(rows[2].threadId == nil)
    }

    /// A guarded row says "continues automatically" only while the Engine will still continue it.
    @Test func sessionRowContinueStatuses() {
        func row(guarded: Bool, _ status: ContinueStatus?) -> SessionRow.State? {
            let tabs = [EngineTab(tab: tab("ttys001", cwd: "/Users/me/alpha"), isGuarded: guarded, threadId: "019a0000-aaaa",
                                  isWaiting: true, continueStatus: status)]
            let sessions = [session("019a0000-aaaa", cwd: "/Users/me/alpha", waiting: true)]
            return SessionsPresentation.rows(tabs: tabs, sessions: sessions, snapshot: snapshot(fiveHour: 0, weekly: 1), now: now).first?.state
        }
        #expect(row(guarded: true, nil) == .waitingGuarded)
        #expect(row(guarded: true, .confirming) == .confirming)
        #expect(row(guarded: true, .unconfirmed) == .unconfirmed)
        #expect(row(guarded: true, .settled) == .settled)
        #expect(row(guarded: false, .unconfirmed) == .unconfirmed)
        #expect(row(guarded: false, .confirming) == .confirming)
        #expect(row(guarded: false, .settled) == .waitingNotGuarded)
        #expect(row(guarded: false, nil) == .waitingNotGuarded)
    }

    @Test func sessionRowsWithoutSnapshotAreNeverAmbiguous() {
        let tabs = [EngineTab(tab: tab("ttys003", cwd: "/Users/me/gamma"), isGuarded: false, threadId: nil, isWaiting: false)]
        let sessions = [session("019c0000-cccc", cwd: "/Users/me/gamma", waiting: true)]
        #expect(SessionsPresentation.rows(tabs: tabs, sessions: sessions, snapshot: nil, now: now).map(\.state) == [.idle])
    }

    /// A tab whose folder is unknown could hold any waiting conversation that no tab claimed.
    @Test func tabWithoutFolderIsAmbiguousWhenAnUnclaimedSessionWaits() {
        let tabs = [
            EngineTab(tab: tab("ttys007", cwd: nil), isGuarded: false, threadId: nil, isWaiting: false),
            EngineTab(tab: tab("ttys008", cwd: "/Users/me/alpha"), isGuarded: false, threadId: "019a0000-aaaa", isWaiting: true),
        ]
        let claimed = [session("019a0000-aaaa", cwd: "/Users/me/alpha", waiting: true)]
        #expect(SessionsPresentation.rows(tabs: tabs, sessions: claimed, snapshot: snapshot(fiveHour: 100, weekly: 1), now: now)
            .map(\.state) == [.idle, .waitingNotGuarded])
        let unclaimed = claimed + [session("019e0000-eeee", cwd: "/elsewhere", waiting: true)]
        #expect(SessionsPresentation.rows(tabs: tabs, sessions: unclaimed, snapshot: snapshot(fiveHour: 100, weekly: 1), now: now)
            .map(\.state) == [.ambiguous, .waitingNotGuarded])
    }

    // MARK: - Status line

    @Test func statusLineOrder() {
        func status(engine: Bool = true, codex: Bool = true, snapshot: Bool = true, error: LimitsReadFailure? = nil,
                    paused: Bool = false, tabs: Int = 1, guarded: Int = 1) -> PopoverStatus {
            PopoverStatus.make(engineRunning: engine, codexFound: codex, hasSnapshot: snapshot, readFailure: error,
                               isPaused: paused, tabCount: tabs, guardedCount: guarded)
        }
        #expect(status(engine: false, codex: false) == .starting)
        #expect(status(codex: false, error: .unreachable) == .codexMissing)
        #expect(status(error: .notSignedIn) == .notSignedIn)
        #expect(status(snapshot: false, error: .notSignedIn) == .notSignedIn)
        #expect(status(error: .unreachable) == .readFailed)
        #expect(status(error: .other("rpc error 1: boom")) == .readFailed)
        #expect(status(snapshot: false) == .reading)
        #expect(status(paused: true, tabs: 0) == .paused)
        #expect(status(tabs: 0, guarded: 0) == .noCodexTab)
        #expect(status(tabs: 3, guarded: 2) == .watching(guarded: 2))
        #expect(status(tabs: 2, guarded: 0) == .watching(guarded: 0))
    }

    // MARK: - Read failures

    @Test(arguments: [
        "Unauthorized", "not logged in, run codex login", "Please sign in with ChatGPT", "auth token expired",
        "HTTP 401 from backend", "AUTHENTICATION REQUIRED",
    ])
    func authRPCErrorsMeanNotSignedIn(message: String) {
        #expect(LimitsReadFailure.classify(AppServerError.rpcError(code: -32000, message: message)) == .notSignedIn)
    }

    @Test func authByCode() {
        #expect(LimitsReadFailure.classify(AppServerError.rpcError(code: 401, message: "denied")) == .notSignedIn)
    }

    @Test func otherFailures() {
        #expect(LimitsReadFailure.classify(AppServerError.timeout) == .unreachable)
        #expect(LimitsReadFailure.classify(AppServerError.transportExited(1)) == .unreachable)
        #expect(LimitsReadFailure.classify(AppServerError.notStarted) == .unreachable)
        #expect(LimitsReadFailure.classify(AppServerError.rpcError(code: -32601, message: "method not found"))
            == .other("rpc error -32601: method not found"))
        #expect(LimitsReadFailure.classify(ProtocolDecodingError(message: "bad frame")) == .other("bad frame"))
    }

    // MARK: - Use Reset after the confirmation

    @Test func creditIsCheckedAgainAfterConfirmation() {
        let current = snapshot(fiveHour: 100, weekly: 40, credits: [
            credit("a", expiresIn: 3600), credit("b", expiresIn: 7200, status: .redeemed),
        ])
        #expect(CreditPresentation.stillAvailable(creditId: "a", in: current))
        #expect(!CreditPresentation.stillAvailable(creditId: "b", in: current))
        #expect(!CreditPresentation.stillAvailable(creditId: "gone", in: current))
        #expect(!CreditPresentation.stillAvailable(creditId: "a", in: nil))
    }

    @Test func popoverMaxContentHeightLeavesRoomAndHasAFloor() {
        #expect(PopoverLayout.maxContentHeight(visibleScreenHeight: 1200) == 520)
        #expect(PopoverLayout.maxContentHeight(visibleScreenHeight: 900) == 520)
        #expect(PopoverLayout.maxContentHeight(visibleScreenHeight: 600) == 440)
        #expect(PopoverLayout.maxContentHeight(visibleScreenHeight: 400) == 300)
    }

    @Test func onlyTheExactKnownCreditTitleIsMapped() {
        #expect(CreditPresentation.localizationKey(forTitle: "Full reset (Weekly + 5 hr)") == "popover.resets.title.fullReset")
        #expect(CreditPresentation.localizationKey(forTitle: "full reset (weekly + 5 hr)") == nil)
        #expect(CreditPresentation.localizationKey(forTitle: "Bonus reset") == nil)
        #expect(CreditPresentation.localizationKey(forTitle: nil) == nil)
    }

    @Test func onlyShortSingleLineThreadNamesAreShown() {
        #expect(SessionsPresentation.displayName("Fix the parser") == "Fix the parser")
        #expect(SessionsPresentation.displayName("line one\nline two") == nil)
        #expect(SessionsPresentation.displayName(String(repeating: "a", count: 41)) == nil)
        #expect(SessionsPresentation.displayName(String(repeating: "a", count: 40)) != nil)
        #expect(SessionsPresentation.displayName("   ") == nil)
        #expect(SessionsPresentation.displayName("bir şey yapacak…") == nil)
    }

    @Test func sessionNoteDependsOnPauseAndAutoContinue() {
        typealias P = SessionsPresentation
        #expect(P.note(state: .waitingGuarded, paused: false, autoContinue: true) == .continuesAutomatically)
        #expect(P.note(state: .waitingGuarded, paused: true, autoContinue: true) == .pausedResumeContinues)
        #expect(P.note(state: .waitingGuarded, paused: true, autoContinue: false) == .autoContinueOff)
        #expect(P.note(state: .waitingGuarded, paused: false, autoContinue: false) == .autoContinueOff)
        #expect(P.note(state: .waitingNotGuarded, paused: true, autoContinue: false) == .waitingNotGuarded)
        #expect(P.note(state: .idle, paused: true, autoContinue: true) == .none)
        #expect(P.note(state: .ambiguous, paused: false, autoContinue: true) == .ambiguous)
    }
}
