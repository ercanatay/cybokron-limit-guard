import Foundation
import Testing
@testable import LimitGuardCore

@Suite("Store")
struct StoreTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func settingsIgnoreTheRetiredPermissionMissingToggle() throws {
        let url = try tempDir().appendingPathComponent("settings.json")
        try Data(#"{"schemaVersion":1,"notify":{"permissionMissing":false,"readOnly":false}}"#.utf8).write(to: url)
        let s = try #require(try JSONStore<Settings>(url: url, schemaVersion: 1).load())
        #expect(!s.notify.readOnly && s.notify.limitReached)
    }

    @Test func roundTripsSettingsWithDefaults() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("nested/settings.json")
        let store = JSONStore<Settings>(url: url, schemaVersion: 1)
        #expect(try store.load() == nil)

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1}"#.utf8).write(to: url)
        let s = try #require(try store.load())
        #expect(s == Settings())
        #expect(s.autoContinue && s.countdownSeconds == 10 && s.maxContinues == 3 && s.minGapSeconds == 120)
        #expect(!s.autoSpendEnabled && s.autoSpendThreshold == 97)
        #expect(s.expiryReminders && s.keepAwake && s.showPercentInMenuBar && s.launchAtLogin)
        #expect(!s.guardNewTabsAutomatically)
        #expect(s.noticeAcceptedVersion == nil && s.noticeAcceptedAt == nil && s.codexPathOverride == nil)
        #expect(s.language == .system)
        #expect(s.continueTexts == ["tr": "devam et", "en": "continue"] && s.fallbackText == "continue")
        #expect(s.notify == NotificationToggles())
        #expect(s.notify.limitReached && s.notify.readOnly)

        var changed = s
        changed.countdownSeconds = 25
        changed.language = .turkish
        changed.noticeAcceptedVersion = 1
        changed.noticeAcceptedAt = Date(timeIntervalSince1970: 1_700_000_000)
        changed.notify.resetUsed = false
        try store.save(changed)
        #expect(try store.load() == changed)
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains(#""schemaVersion" : 1"#))
    }

    @Test func partialAndUnknownValuesDecode() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("settings.json")
        try Data(#"{"schemaVersion":1,"countdownSeconds":30,"language":"klingon","notify":{"resetUsed":false},"future":1}"#.utf8).write(to: url)
        let s = try #require(try JSONStore<Settings>(url: url, schemaVersion: 1).load())
        #expect(s.countdownSeconds == 30 && s.language == .system && !s.notify.resetUsed && s.notify.limitReached)
    }

    @Test func newerSchemaThrows() throws {
        let url = try tempDir().appendingPathComponent("settings.json")
        try Data(#"{"schemaVersion":2}"#.utf8).write(to: url)
        #expect(throws: StoreError.newerSchema(found: 2)) {
            try JSONStore<Settings>(url: url, schemaVersion: 1).load()
        }
    }

    @Test func appStateRoundTripsAndDefaults() throws {
        let url = try tempDir().appendingPathComponent("state.json")
        let store = JSONStore<AppState>(url: url, schemaVersion: 1)
        try Data(#"{"schemaVersion":1}"#.utf8).write(to: url)
        #expect(try store.load() == AppState())
        #expect(try store.load()?.paused == false)

        var state = AppState()
        state.loop["t1"] = LoopRecord(consecutive: 2, lastSentAt: Date(timeIntervalSince1970: 1_700_000_000), shortTurnsInARow: 1)
        state.autoSpend = AutoSpendMarker(accountId: "acct", spentAt: Date(timeIntervalSince1970: 1_700_100_000))
        let ref = TabRef(windowId: 3, tabIndex: 1, tty: "/dev/ttys004")
        state.guardedTabs = [GuardedTab(ref: ref, addedAt: Date(timeIntervalSince1970: 1_700_000_100))]
        state.scheduled = ScheduledContinue(threadId: "t1", text: "continue", fireAt: Date(timeIntervalSince1970: 1_700_000_200))
        state.pendingDeliveries = [PendingDelivery(threadId: "t1", clientMessageId: UUID(), text: "continue", sentAt: Date(timeIntervalSince1970: 1_700_000_300))]
        state.expiryNotified = ["credit-1"]
        state.paused = true
        state.stops["t1"] = StopInfo(turnId: "u1", isWeekly: true, resetsAt: Date(timeIntervalSince1970: 1_700_200_000))
        try store.save(state)
        #expect(try store.load() == state)
    }

    @Test func activityKeeps100() throws {
        let log = ActivityLog(url: try tempDir().appendingPathComponent("activity.json"))
        for i in 0..<130 {
            try log.append(ActivityEntry(date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), kind: .continueSent, detail: "\(i)"))
        }
        let all = try log.entries()
        #expect(all.count == 100)
        #expect(all.first?.detail == "30" && all.last?.detail == "129")
        try log.clear()
        #expect(try log.entries().isEmpty)
    }

    @Test func unknownActivityKindDecodesAsError() throws {
        let url = try tempDir().appendingPathComponent("activity.json")
        try Data(#"{"schemaVersion":1,"entries":[{"date":"2026-10-29T10:00:00Z","kind":"somethingNew"}]}"#.utf8).write(to: url)
        let entries = try ActivityLog(url: url).entries()
        #expect(entries.count == 1 && entries[0].kind == .error)
    }

    @Test func usageHistoryThrottlesPerMinuteAndPrunes30Days() throws {
        let history = UsageHistory(url: try tempDir().appendingPathComponent("usage-history.json"))
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(try history.append(sample: UsageSample(date: t0, fiveHour: 10, weekly: 20)))
        #expect(try !history.append(sample: UsageSample(date: t0.addingTimeInterval(30), fiveHour: 11, weekly: 21)))
        #expect(try history.append(sample: UsageSample(date: t0.addingTimeInterval(60), fiveHour: 12, weekly: 22)))
        #expect(try history.samples().count == 2)
        let later = t0.addingTimeInterval(31 * 24 * 3600)
        #expect(try history.append(sample: UsageSample(date: later, fiveHour: nil, weekly: 30)))
        let kept = try history.samples()
        #expect(kept.count == 1 && kept[0].date == later && kept[0].fiveHour == nil)
    }

    @Test func preDowngradeCopiesEveryJSON() throws {
        let dir = try tempDir()
        try Data("{\"a\":1}".utf8).write(to: dir.appendingPathComponent("settings.json"))
        try Data("{\"b\":2}".utf8).write(to: dir.appendingPathComponent("state.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try makePreDowngradeCopies(in: dir, timestamp: "20261029-1000")
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(names.contains("settings.pre-downgrade-20261029-1000.json"))
        #expect(names.contains("state.pre-downgrade-20261029-1000.json"))
        #expect(!names.contains("notes.pre-downgrade-20261029-1000.json"))
        #expect(try Data(contentsOf: dir.appendingPathComponent("state.pre-downgrade-20261029-1000.json")) == Data("{\"b\":2}".utf8))
        // Running again must not copy the copies or fail.
        try makePreDowngradeCopies(in: dir, timestamp: "20261029-1000")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 5)
    }
}

@Suite("Notice")
struct NoticeTests {
    @Test func noticeShownWhenNeverAccepted() {
        #expect(Notice.mustShow(settings: Settings()))
    }

    @Test func noticeShownAgainOnVersionBump() {
        var s = Settings()
        s.noticeAcceptedVersion = Notice.currentVersion - 1
        #expect(Notice.mustShow(settings: s))
    }

    @Test func noticeHiddenWhenCurrent() {
        var s = Settings()
        s.noticeAcceptedVersion = Notice.currentVersion
        #expect(!Notice.mustShow(settings: s))
    }
}
