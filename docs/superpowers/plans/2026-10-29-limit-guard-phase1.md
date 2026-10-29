# Cybokron Limit Guard Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Rulings during execution** (spec decisions D31–D34, `docs/design/limit-guard-spec.md`): delivery is
> app-server only (no Terminal typing or Automation permission in Phase 1, D31); auto-spend is limited to
> one per account every 7 days via an `AutoSpendMarker` written before consume (D32); no "LG" letters
> anywhere (D33); subagent threads are excluded (D34). Where a task below still mentions Terminal
> typing, Apple Events or a per-weekly-window marker, these rulings win.

**Goal:** Ship v0.1.0 of a macOS menu-bar app that shows Codex usage and reset credits, continues Codex CLI sessions in owner-selected Terminal tabs after a usage-limit stop, and (opt-in) spends one reset credit before the weekly limit runs out.

**Architecture:** Two targets like Cybokron Dock Groups: `LimitGuardCore` (pure, unit-tested logic: decoding, policies, persistence, app-server client behind protocols) and `CybokronLimitGuard` (SwiftUI/AppKit menu-bar app, Terminal/Apple Events, notifications). Everything that touches Codex goes through `codex app-server` (JSON-RPC over stdio); session state is read from `~/.codex` read-only. Policies are pure functions over value types so every automatic action is decided in tested code.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, SwiftUI + AppKit, Swift Charts, NaturalLanguage, ServiceManagement, UserNotifications, IOKit (power assertions), SQLite3 (system library), Swift Testing (`import Testing`), SwiftPM for tests, XcodeGen for the app project. No third-party packages.

**Spec:** `docs/design/limit-guard-spec.md` (decisions D1–D30). Read it before any task.

## Global Constraints

- macOS 14.0+, bundle id `com.cybokron.limitguard`, app name "Cybokron Limit Guard", `LSUIElement = YES`.
- No third-party dependencies, no SPM packages (system frameworks only).
- Not sandboxed; hardened runtime; Developer ID signed + notarized for releases (D13).
- Never read `~/.codex/auth.json` or any credential; all account calls go through `codex app-server`.
- Open `~/.codex/state_5.sqlite` read-only (`SQLITE_OPEN_READONLY`); never write into `~/.codex`.
- The real `account/rateLimitResetCredit/consume` is **never** called from tests or during development (D17); all spend paths run against `FakeAppServer`.
- Every user-visible string goes through `L10n` with keys in `Resources/en.lproj/Localizable.strings` and `Resources/tr.lproj/Localizable.strings`.
- Turkish strings: `~/.claude/scripts/haiku-translate.sh tr < en-chunk > tr-chunk` (one call per language); fallback = one Haiku subagent per language under 100K tokens; main model reviews.
- Commit messages and docs in English; the signing team's organisation name never appears in repo, commits or release text.
- Version: `MARKETING_VERSION 0.1.0`, `CURRENT_PROJECT_VERSION 100` (major*10000+minor*100+patch).
- Data dir: `~/Library/Application Support/Cybokron Limit Guard/`; every JSON file has `schemaVersion: 1`.
- Default values (spec): poll 5 min / 1 min when ≥ 90 % or continue pending; countdown 10 s; max continues 3; min gap 2 min; runaway brake 3 turns < 60 s; auto-spend off; threshold 97 % used; in-use window 30 min; skip if weekly resets within 12 h; stop age 24 h (weekly stop: `secondary.resetsAt + 1 h`); keep-awake on; % in menu bar on; launch at login on; guard new tabs off; continue texts `tr: "devam et"`, `en: "continue"`, fallback `"continue"`; language confidence ≥ 0.6.
- Tests: `scripts/test.sh` (SwiftPM). App build: `scripts/build-app.sh`.

## Review Focus

1. **Codex updated and a reply shape changed** (e.g. `ordinaryUsageAllowed` missing, new enum value) → app must go read-only: show data, never type, never spend. Test: Task 2 `missingOrdinaryUsageAllowedIsReadOnly`.
2. **Owner typed something between the stop and the scheduled continue** → nothing is sent. Test: Task 6 `userMessageAfterStopMakesIneligible`, re-checked in Task 11 `recheckBeforeSendAborts`.
3. **App quits/crashes while a consume call is in flight** → next launch retries with the same idempotency key and credit, never a second credit. Test: Task 8 `pendingLedgerEntryIsRetriedWithSameKey`.
4. **Mac sleeps through the reset time** → on wake the continue still runs only if the stop is within the age rule; a weekly stop uses `resetsAt + 1 h`. Test: Task 7 `weeklyStopUsesResetsAtPlusOneHour`, Task 11 `wakeRunsMissedContinueOnce`.
5. **Two guarded tabs, delivery falls back to typing and mapping is ambiguous** → type nothing, notify. Test: Task 10 `ambiguousMappingReturnsNil`.

---

## File Structure

```
cybokron-limit-guard/
  Package.swift                      SwiftPM: LimitGuardCore, CybokronLimitGuard (exe), LimitGuardCoreTests
  project.yml                        XcodeGen (copied pattern from Dock Groups)
  scripts/                           build-app.sh, make-dmg.sh, notarize.sh, check-version.sh,
                                     release-notes.sh, swiftpm-env.sh, test.sh, generate-app-icon.swift
  .github/workflows/swift.yml        CI (tests on PR; v* tag → notarized DMG draft release)
  Resources/                         Info.plist, CybokronLimitGuard.entitlements, Assets.xcassets,
                                     en.lproj/Localizable.strings, tr.lproj/Localizable.strings
  Sources/LimitGuardCore/
    Codex/        CodexLocator.swift, AppServerTransport.swift, AppServerClient.swift,
                  AccountModels.swift, CodexAccountService.swift, ProtocolGuard.swift
    Sessions/     RolloutEvent.swift, RolloutReader.swift, ThreadIndex.swift (SQLite),
                  SessionState.swift, SessionScanner.swift
    Language/     LanguageSample.swift, ContinueText.swift
    Policy/       ContinuePolicy.swift, ResetPolicy.swift, Forecast.swift
    Reset/        ResetLedger.swift, ResetExecutor.swift
    Delivery/     Delivery.swift (protocol + result), AppServerDelivery.swift, TabMatcher.swift
    Store/        JSONStore.swift, Settings.swift, AppState.swift, ActivityLog.swift, UsageHistory.swift
    Localization/ Localization.swift
    Updates/, Changelog/             copied from Dock Groups, renamed module/strings
    Engine/       Engine.swift (orchestration, clock + scheduler injected), Clock.swift
  Sources/CybokronLimitGuard/
    App/          CybokronLimitGuardApp.swift, AppDelegate.swift, InstanceHandoff.swift
    Terminal/     TerminalBridge.swift (Apple Events), TerminalTypingDelivery.swift
    System/       Notifier.swift, KeepAwake.swift, LoginItem.swift, Diagnostics.swift
    MenuBar/      StatusItemController.swift, PopoverView.swift, LimitBarView.swift,
                  ResetCreditsView.swift, GuardedTabsView.swift, NextActionView.swift
    Windows/      LegalNoticeWindow.swift, ActivityWindow.swift, UsageChartWindow.swift
    Settings/     SettingsWindowController.swift, General/Continue/Resets/Notifications/
                  Updates/Changelog/Support SettingsView.swift
    About/        AboutData.swift, AboutContentView.swift, AboutWindowController.swift, SocialIcons.swift
    Support/      L10n.swift
  Tests/LimitGuardCoreTests/
    Fixtures/     rate-limits-live.json, rate-limits-missing-gate.json, usage-live.json,
                  rollout-finished.jsonl, rollout-usage-limit.jsonl, rollout-limit-then-user.jsonl,
                  rollout-overloaded.jsonl, consume-*.json
    FakeAppServer.swift, *Tests.swift
  docs/design/limit-guard-spike.md   spike results (Task 0)
```

---

### Task 0: Spikes S1–S5 (throwaway, decides Task 10/11 shape)

**Files:**
- Create: `docs/design/limit-guard-spike.md`
- Scratch scripts in the session scratchpad only (not committed).

**Interfaces:**
- Produces: a written verdict per spike that Tasks 10–11 follow: `PRIMARY_DELIVERY = appServer | terminalTyping`, Terminal `do script` behaviour, the exact text visible in a tab after a limit stop (picker or plain), app-server lifetime choice.

- [ ] **Step 1: S5 — delivery via app-server.** With one Codex TUI open in Terminal on a throwaway directory, run a scratch script that pipes JSON-RPC into `codex app-server proxy`: `initialize` → `initialized` → `thread/loaded/list`. Record whether the TUI's thread id appears. Then `turn/start {threadId, input:[{type:"text",text:"Reply with the single word PONG"}], clientUserMessageId:<uuid>}`. Record: does the turn appear in the Terminal tab, does the TUI stay in sync, is `clientUserMessageId` visible in the rollout, model/approval unchanged? Ask the owner before running (it sends a real prompt; costs a few tokens).
- [ ] **Step 2: S1 — Terminal typing.** In the same tab, from `osascript`: `tell application "Terminal" to do script "Reply with PONG" in tab 1 of window id <id>`. Record: submitted / newline only / bracketed paste. Repeat with a half-typed draft in the composer and record the result.
- [ ] **Step 3: S3 — Terminal scripting reads.** Record values of `tty`, `busy`, `processes`, `custom title`, and time to read `history` of a long tab.
- [ ] **Step 4: S2 — tab ↔ thread.** Two Codex tabs in different cwds: record whether `thread/loaded/list` + thread `cwd` + process cwd (`lsof -a -p <pid> -d cwd`) separate them.
- [ ] **Step 5: S4 — app-server lifetime.** Long-lived `codex app-server proxy` child for 30 min vs spawn per poll: RSS, CPU, and whether the shared daemon is required (`proxy` fails if no daemon → fall back to private `codex app-server`).
- [ ] **Step 6: Limit-stop screen.** At the owner's next natural limit stop, capture the tab text (`history` tail) — plain message vs option picker. (May land after Task 11; Task 11's picker guard uses the strings from §9 meanwhile.)
- [ ] **Step 7: Write `docs/design/limit-guard-spike.md`** with a verdict per spike, then commit.

```bash
git add docs/design/limit-guard-spike.md
git commit -m "docs: record Phase 1 spike results"
```

**Gate:** if S5 works, Task 10 implements `AppServerDelivery` as primary and Task 11's `TerminalTypingDelivery` as fallback; if S5 fails, Terminal typing is primary and the guarded-tab mapping rules of spec §7.3 apply in full.

---

### Task 1: Project scaffold, localisation infrastructure, CI

**Files:**
- Create: `Package.swift`, `project.yml`, `scripts/*` (copy from `~/Documents/GitHub/cybokron-dock-groups/scripts`, rename targets/paths/names), `.github/workflows/swift.yml` (copy, rename), `Resources/Info.plist`, `Resources/CybokronLimitGuard.entitlements`, `Resources/en.lproj/Localizable.strings`, `Resources/tr.lproj/Localizable.strings`, `Sources/LimitGuardCore/Localization/Localization.swift`, `Sources/CybokronLimitGuard/Support/L10n.swift`, `Sources/CybokronLimitGuard/App/CybokronLimitGuardApp.swift`, `.gitignore`, `CHANGELOG.md`, `AGENTS.md`
- Test: `Tests/LimitGuardCoreTests/LocalizationTests.swift`

**Interfaces:**
- Produces: `Localization.string(_ key: String, bundle: Bundle) -> String`, `Localization.format(_ key: String, _ args: CVarArg...) -> String` (same API as Dock Groups' `Localization`); app-side `enum L10n` namespaces.

- [ ] **Step 1:** Copy Dock Groups' `Package.swift`/`project.yml` structure with targets `LimitGuardCore` (static lib), `CybokronLimitGuard` (app/executable), `LimitGuardCoreTests`; `linkerSettings: [.linkedLibrary("sqlite3")]` on `LimitGuardCore`. Info.plist: `LSUIElement YES`, `NSAppleEventsUsageDescription` = "Cybokron Limit Guard sends a continue message to the Codex session you chose in Terminal." Entitlements: `com.apple.security.automation.apple-events = true`, no sandbox.
- [ ] **Step 2: Write the failing test** `LocalizationTests`: (a) every key in `en.lproj` exists in `tr.lproj` and vice versa; (b) placeholder sets (`%@`, `%d`, `%1$@` …) equal per key; (c) every `"key"` literal used in `Sources/**/L10n.swift` exists in `en.lproj`. Port from Dock Groups' `LocalizationTests`.
- [ ] **Step 3: Run** `scripts/test.sh --filter Localization` → FAIL (no strings files / sources).
- [ ] **Step 4:** Add `Localization.swift`, an `L10n` with `L10n.App.name`, a minimal `MenuBarExtra`-free AppKit status item showing "LG" so the app launches; en/tr strings for the keys used.
- [ ] **Step 5: Run** `scripts/test.sh` → PASS; `scripts/build-app.sh` → builds `build/Cybokron Limit Guard.app`; launch it and see the status item.
- [ ] **Step 6:** CI: tests on push/PR; release job on `v*` tag copied (environment `release`, `NOTARIZE_ENABLED`), names changed. Configure repo secrets/variables later in Task 18 (do not copy secrets now).
- [ ] **Step 7: Commit** `chore: scaffold app, localisation and CI`.

---

### Task 2: Account models, tolerant decoding, ProtocolGuard

**Files:**
- Create: `Sources/LimitGuardCore/Codex/AccountModels.swift`, `Sources/LimitGuardCore/Codex/ProtocolGuard.swift`
- Create fixtures: `Tests/LimitGuardCoreTests/Fixtures/rate-limits-live.json` (the 2026-10-29 probe result, credit ids kept, `accountId` replaced by `"acct-test"`), `rate-limits-missing-gate.json` (same without `ordinaryUsageAllowed`), `rate-limits-unknown-enum.json` (`status: "frozen"`), `usage-live.json` (5 buckets + summary)
- Test: `Tests/LimitGuardCoreTests/AccountModelsTests.swift`

**Interfaces:**
- Produces:
  - `struct RateLimitWindow: Equatable, Sendable { usedPercent: Double; windowMinutes: Int?; resetsAt: Date? }`
  - `enum ResetCreditStatus: Equatable, Sendable { available, redeeming, redeemed, unknown(String) }`
  - `struct ResetCredit: Equatable, Sendable, Identifiable { id: String; status: ResetCreditStatus; grantedAt: Date; expiresAt: Date?; title: String?; detail: String? }`
  - `struct AccountSnapshot: Equatable, Sendable { ordinaryUsageAllowed: Bool?; fiveHour: RateLimitWindow?; weekly: RateLimitWindow?; planType: String?; reachedType: String?; accountId: String?; credits: [ResetCredit]; availableCreditCount: Int; readAt: Date }`
  - `struct DailyUsage: Equatable, Sendable { day: String; tokens: Int64 }`, `struct UsageReport: Equatable, Sendable { daily: [DailyUsage]?; peakDailyTokens: Int64?; currentStreakDays: Int? }`
  - `enum ConsumeOutcome: Equatable, Sendable { reset, nothingToReset, noCredit, alreadyRedeemed }`
  - `enum ProtocolHealth: Equatable, Sendable { full, readOnly(reason: String) }`
  - `AccountSnapshot.decode(from json: Data, readAt: Date) throws -> (AccountSnapshot, ProtocolHealth)`
  - `UsageReport.decode(from json: Data) throws -> UsageReport`
  - `ConsumeOutcome.decode(from json: Data) -> ConsumeOutcome?` (nil on unknown)
  - Credits sorted: earliest `expiresAt` first, `nil` last.

- [ ] **Step 1: Write failing tests:**
  - `decodesLiveSnapshot`: allowed == false, fiveHour.usedPercent == 100, fiveHour.windowMinutes == 300, weekly.usedPercent == 59, weekly.windowMinutes == 10080, credits.count == 2, credits[0].id == "RateLimitResetCredit_3509ea3582e88191b472658ffebbe55f", credits[0].expiresAt == Date(timeIntervalSince1970: 1793302182), health == .full.
  - `missingOrdinaryUsageAllowedIsReadOnly`: health is `.readOnly`, allowed == nil, windows still decoded.
  - `unknownCreditStatusDecodesAsUnknown`: status == `.unknown("frozen")`, health == `.full` (the credit is simply not available).
  - `bigintFieldsDecode`: `usage-live.json` → daily.count == 5, daily.last.tokens == 248173462.
  - `consumeOutcomes`: each of the four strings → enum; `"weird"` → nil.
- [ ] **Step 2: Run** `scripts/test.sh --filter AccountModels` → FAIL.
- [ ] **Step 3: Implement** with `JSONSerialization` (tolerant: ignore unknown keys; `bigint` values may arrive as numbers). Read-only when: result object missing, `ordinaryUsageAllowed` key missing, `rateLimits` missing, a credit lacks `id`/`status`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(core): decode Codex account snapshot tolerantly`.

---

### Task 3: App-server client (JSON-RPC over stdio) + FakeAppServer

**Files:**
- Create: `Sources/LimitGuardCore/Codex/AppServerTransport.swift`, `Sources/LimitGuardCore/Codex/AppServerClient.swift`, `Sources/LimitGuardCore/Codex/CodexLocator.swift`
- Create: `Tests/LimitGuardCoreTests/FakeAppServer.swift`
- Test: `Tests/LimitGuardCoreTests/AppServerClientTests.swift`, `CodexLocatorTests.swift`

**Interfaces:**
- Produces:
  - `protocol AppServerTransport: AnyObject, Sendable { func start() throws; func send(_ line: Data) throws; var onLine: (@Sendable (Data) -> Void)? { get set }; var onExit: (@Sendable (Int32) -> Void)? { get set }; func stop() }`
  - `final class ProcessTransport: AppServerTransport` — `init(executable: URL, arguments: [String])` (arguments `["app-server", "proxy"]` or `["app-server"]` per Task 0 S4).
  - `actor AppServerClient { init(transportFactory: @escaping @Sendable () -> AppServerTransport, clientName: String, clientVersion: String); func request(_ method: String, params: [String: Any]?, timeout: Duration) async throws -> Data /* raw "result" JSON */; func shutdown() }` — performs `initialize`/`initialized` once per transport, matches responses by `id`, restarts the transport on exit with back-off 1 s, 2 s, 5 s, 30 s.
  - `enum AppServerError: Error, Equatable { timeout, transportExited(Int32), rpcError(code: Int, message: String), notStarted }`
  - `struct CodexLocator { func resolve(override: String?) -> URL?; func version(of url: URL) async -> String? }` — order: override → `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` → `PATH` lookup (`/usr/bin/env which codex` via login shell PATH) → `~/.local/bin/codex`; resolves symlinks.
  - Test helper `final class FakeAppServer: AppServerTransport` — scripted responses per method, records requests, can delay/drop/exit.

- [ ] **Step 1: Write failing tests:**
  - `handshakeThenRequest`: first two lines sent are `initialize` (with `clientInfo.name == "cybokron-limit-guard"`) and `initialized`; then the request; returns the scripted result.
  - `matchesResponsesById`: two concurrent requests answered out of order resolve correctly.
  - `timesOut`: no answer within 50 ms → `.timeout`.
  - `restartsAfterExit`: transport exits; next request re-handshakes on a new transport.
  - `rpcErrorSurfaces`: `{"id":2,"error":{"code":-32600,"message":"x"}}` → `.rpcError(code: -32600, message: "x")`.
  - `locatorPrefersOverride`, `locatorFallsBackToChatGPTPath` (inject a file-exists closure).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(core): JSON-RPC client for codex app-server`.

---

### Task 4: CodexAccountService

**Files:**
- Create: `Sources/LimitGuardCore/Codex/CodexAccountService.swift`
- Test: `Tests/LimitGuardCoreTests/CodexAccountServiceTests.swift`

**Interfaces:**
- Consumes: `AppServerClient`, Task 2 decoders.
- Produces: `actor CodexAccountService { init(client: AppServerClient, now: @escaping @Sendable () -> Date); func readLimits() async throws -> (AccountSnapshot, ProtocolHealth); func readUsage() async throws -> UsageReport; func consume(creditId: String, idempotencyKey: UUID, timeout: Duration) async throws -> ConsumeOutcome? }` — methods `account/rateLimits/read`, `account/usage/read` (params `{}`), `account/rateLimitResetCredit/consume` (params `{"idempotencyKey": key.uuidString.lowercased(), "creditId": creditId}`).

- [ ] **Step 1: Write failing tests** with `FakeAppServer`: `readLimitsUsesMethodName` (method string exact), `consumeSendsExactParams` (lowercased UUID, explicit creditId), `consumeUnknownOutcomeReturnsNil`.
- [ ] **Step 2–4:** run FAIL → implement → run PASS.
- [ ] **Step 5: Commit** `feat(core): Codex account service`.

---

### Task 5: Persistence — JSONStore, Settings, AppState, ActivityLog, UsageHistory

**Files:**
- Create: `Sources/LimitGuardCore/Store/{JSONStore,Settings,AppState,ActivityLog,UsageHistory}.swift`
- Test: `Tests/LimitGuardCoreTests/StoreTests.swift`

**Interfaces:**
- Produces:
  - `struct JSONStore<Value: Codable> { init(url: URL, schemaVersion: Int); func load() throws -> Value?; func save(_ value: Value) throws /* atomic write */ }`; `enum StoreError: Error { newerSchema(found: Int) }`.
  - `struct Settings: Codable, Equatable` with the defaults from Global Constraints, plus `noticeAcceptedVersion: Int?`, `noticeAcceptedAt: Date?`, `codexPathOverride: String?`, `language: AppLanguage (.system/.english/.turkish)`, `continueTexts: [String: String]`, `fallbackText: String`, `notify: NotificationToggles`, `guardNewTabsAutomatically: Bool`.
  - `struct AppState: Codable, Equatable { var loop: [String /*threadId*/: LoopRecord]; var autoSpendWindowKey: Date? /* secondary.resetsAt of the window already spent in */; var autoSpendAccountId: String?; var scheduled: ScheduledContinue?; var pendingDeliveries: [PendingDelivery]; var guardedTabs: [GuardedTab]; var expiryNotified: Set<String> }`
  - `struct LoopRecord: Codable, Equatable { var consecutive: Int; var lastSentAt: Date?; var shortTurnsInARow: Int }`
  - `struct ActivityEntry: Codable, Equatable { date: Date; kind: ActivityKind; threadId: String?; tab: String?; text: String?; detail: String?; codexVersion: String? }`; `ActivityLog.append(_:)` keeps the newest 100.
  - `UsageHistory.append(sample: UsageSample)` with ≤ 1 sample/min, keeps 30 days; `struct UsageSample: Codable, Equatable { date: Date; fiveHour: Double?; weekly: Double? }`.
  - `func makePreDowngradeCopies(in dir: URL, timestamp: String) throws` copies every `*.json` to `*.pre-downgrade-<ts>.json`.

- [ ] **Step 1: Write failing tests:** `roundTripsSettingsWithDefaults` (decode `{}` + schemaVersion 1 → all defaults equal spec values), `newerSchemaThrows` (`schemaVersion: 2` → `.newerSchema(found: 2)`), `activityKeeps100`, `usageHistoryThrottlesPerMinuteAndPrunes30Days`, `preDowngradeCopiesEveryJSON`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** `feat(core): versioned JSON stores`.

---

### Task 6: Session reading — rollouts, thread index, session state

**Files:**
- Create: `Sources/LimitGuardCore/Sessions/{RolloutEvent,RolloutReader,ThreadIndex,SessionState,SessionScanner}.swift`, `Sources/LimitGuardCore/Language/LanguageSample.swift`
- Fixtures: `rollout-finished.jsonl`, `rollout-usage-limit.jsonl`, `rollout-limit-then-user.jsonl`, `rollout-overloaded.jsonl`, `rollout-boilerplate-user.jsonl` (real-shaped, trimmed, no private text), `state-fixture.sqlite` built in-test from SQL.
- Test: `Tests/LimitGuardCoreTests/SessionTests.swift`

**Interfaces:**
- Produces:
  - `enum RolloutEvent: Equatable { sessionMeta(id: String, cwd: String, originator: String?, cliVersion: String?), taskStarted(turnId: String, at: Date), taskComplete(turnId: String, at: Date, errorInfo: String? /* codex_error_info */), userMessage(text: String, at: Date, clientMessageId: String?), turnAborted(at: Date), other }`
  - `struct RolloutReader { func tailEvents(of url: URL, maxBytes: Int = 512_000) throws -> [RolloutEvent] }` — reads only the tail, skips the first partial line, parses `session_meta` from the file's first line separately.
  - `struct ThreadIndex { init(databaseURL: URL); func recentThreads(updatedSince: Date) throws -> [ThreadRow] }`; `struct ThreadRow: Equatable { id: String; rolloutPath: URL; cwd: String; originator: String?; updatedAt: Date; archived: Bool; title: String }`. Locates the DB by globbing `~/.codex/state_*.sqlite` (highest number).
  - `enum StopKind: Equatable { none, usageLimit(at: Date, turnId: String), otherError(String) }`
  - `struct SessionState: Equatable { threadId: String; cwd: String; originator: String?; lastStop: StopKind; userActivityAfterStop: Bool; lastActivityAt: Date; lastTurnDurations: [TimeInterval]; languageSample: String; seenClientMessageIds: Set<String> }`
  - `SessionState.build(thread: ThreadRow, events: [RolloutEvent]) -> SessionState`
  - `LanguageSample.extract(from userMessages: [String]) -> String` — last 3 real messages; drops messages starting with `<` (e.g. `<environment_context>`, `<user_instructions>`), messages > 4000 chars, AGENTS.md blocks (`# AGENTS.md instructions` prefix); joined, trimmed to 1000 chars.
  - `actor SessionScanner { init(index: ThreadIndex, reader: RolloutReader); func scan(now: Date) async -> [SessionState] }` — only `originator == "codex-tui"`, not archived, updated within 8 days.

- [ ] **Step 1: Write failing tests:**
  - `finishedTurnIsNotAStop`: `rollout-finished.jsonl` → `lastStop == .none`.
  - `usageLimitStopDetected`: → `.usageLimit(turnId: …)` with the fixture's turn id.
  - `userMessageAfterStopMakesIneligible`: `rollout-limit-then-user.jsonl` → `userActivityAfterStop == true`.
  - `overloadedIsOtherError`: → `.otherError("server_overloaded")`.
  - `boilerplateIsExcludedFromLanguageSample`: sample contains "şu dosyayı düzelt" and not "environment_context".
  - `tailReaderSkipsPartialFirstLine`: 600 KB file → no decoding error, last event correct.
  - `threadIndexReadsReadOnly`: in-test sqlite with `threads` columns from spec §3 → rows; opening with a non-existent path throws, never creates a file.
- [ ] **Step 2–4:** FAIL → implement (SQLite via `import SQLite3`, `sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)`) → PASS.
- [ ] **Step 5: Commit** `feat(core): read Codex sessions and detect usage-limit stops`.

---

### Task 7: Continue policy (pure) + continue text

**Files:**
- Create: `Sources/LimitGuardCore/Policy/ContinuePolicy.swift`, `Sources/LimitGuardCore/Language/ContinueText.swift`
- Test: `Tests/LimitGuardCoreTests/ContinuePolicyTests.swift`, `ContinueTextTests.swift`

**Interfaces:**
- Consumes: `SessionState`, `AccountSnapshot`, `ProtocolHealth`, `Settings`, `LoopRecord`.
- Produces:
  - `enum ContinueDecision: Equatable { notEligible(Reason), waitUntil(Date), waitForGate, countdown(seconds: Int), send, stopLoopGuard, stopRunaway }` with `enum Reason { finished, otherError, userActed, tooOld, notGuarded, paused, readOnly, noticeNotAccepted, autoContinueOff }`
  - `struct ContinueInputs { session: SessionState; snapshot: AccountSnapshot; snapshotAge: TimeInterval; health: ProtocolHealth; settings: Settings; loop: LoopRecord; isGuarded: Bool; paused: Bool; now: Date }`
  - `ContinuePolicy.decide(_ inputs: ContinueInputs) -> ContinueDecision`
  - `ContinuePolicy.stopIsWeekly(snapshot:) -> Bool` (weekly window ≥ 100 % or `reachedType` mentions weekly when 5-hour < 100 %).
  - `ContinueText.resolve(sample: String, table: [String: String], fallback: String) -> (text: String, language: String?)` using `NLLanguageRecognizer`, confidence ≥ 0.6.

- [ ] **Step 1: Write failing tests** (one per row; build inputs with a helper):
  - `finishedSessionNotEligible` → `.notEligible(.finished)`; `otherErrorNotEligible`; `userActedNotEligible`.
  - `noticeNotAcceptedBlocks` → `.notEligible(.noticeNotAccepted)`; `pausedBlocks`; `readOnlyBlocks`; `unguardedBlocks`.
  - `stopOlderThan24hIsTooOld`; `weeklyStopUsesResetsAtPlusOneHour` (stop 3 days old, weekly `resetsAt` = now − 30 min → not too old; `resetsAt` = now − 61 min → `.tooOld`).
  - `beforeResetsAtWaits` → `.waitUntil(fiveHour.resetsAt)`.
  - `gateFalseWaitsForGate`, `gateNilWaitsForGate`, `staleSnapshotWaitsForGate` (age 31 s).
  - `gateTrueStartsCountdown` → `.countdown(seconds: 10)`; with `countdownSeconds = 0` → `.send`.
  - `loopGuardAfterThree` (consecutive 3) → `.stopLoopGuard`; `minGapTwoMinutes` (lastSentAt 90 s ago) → `.waitUntil(lastSentAt + 120)`.
  - `runawayBrake` (shortTurnsInARow 3) → `.stopRunaway`.
  - ContinueText: `turkishSampleGivesDevamEt`, `englishSampleGivesContinue`, `shortAmbiguousGivesFallback` ("ok"), `customTableEntryUsed` (`de: "weiter"` with German sample).
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** `feat(core): continue policy and language-aware continue text`.

---

### Task 8: Reset policy, ledger, executor

**Files:**
- Create: `Sources/LimitGuardCore/Policy/ResetPolicy.swift`, `Sources/LimitGuardCore/Reset/{ResetLedger,ResetExecutor}.swift`
- Test: `Tests/LimitGuardCoreTests/ResetPolicyTests.swift`, `ResetExecutorTests.swift`

**Interfaces:**
- Consumes: `AccountSnapshot`, `ProtocolHealth`, `Settings`, `AppState`, `[SessionState]`, `CodexAccountService`.
- Produces:
  - `enum AutoSpendDecision: Equatable { spend(creditId: String), skip(SkipReason) }`, `SkipReason { disabled, paused, readOnly, noticeNotAccepted, belowThreshold, noCredit, alreadySpentThisWindow, pendingConsume, codexIdle, windowResetsSoon, unknownWindow }`
  - `ResetPolicy.decideAuto(snapshot:health:settings:state:sessions:paused:now:) -> AutoSpendDecision` — in-use = any session with `lastActivityAt ≥ now − 30 min` or an eligible usage-limit stop; resets-soon = `weekly.resetsAt − now < 12 h`; credit = first available after sorting (earliest expiry).
  - `ResetPolicy.expiringSoon(credits:now:) -> [ResetCredit]` (< 24 h).
  - `struct LedgerEntry: Codable, Equatable { idempotencyKey: UUID; creditId: String; reason: SpendReason (.auto/.manual); createdAt: Date; attempts: Int }`
  - `actor ResetLedger { init(store: JSONStore<[LedgerEntry]>); func begin(creditId: String, reason: SpendReason, now: Date) throws -> LedgerEntry; func pending() -> LedgerEntry?; func finish(_ key: UUID) throws; func expireOlderThan(_ age: TimeInterval, now: Date) throws -> [LedgerEntry] }`
  - `actor ResetExecutor { init(service: CodexAccountService, ledger: ResetLedger, now: @escaping @Sendable () -> Date); func spend(creditId: String, reason: SpendReason) async -> SpendResult; func resumePending() async -> SpendResult? }`, `enum SpendResult: Equatable { outcome(ConsumeOutcome), unknown, busy }` — retries timeouts up to 3 times (delays 10 s, 60 s, 240 s; injectable sleeper) with the **same** entry; final outcomes clear the entry; `nil` outcome (unknown string) → keep entry, return `.unknown`, enter read-only via caller.

- [ ] **Step 1: Write failing tests:**
  - Policy: `disabledByDefault`, `belowThresholdSkips` (96.9), `atThresholdSpendsEarliestExpiring` (two credits, picks expiry 1793302182), `fiveHourStateIrrelevant` (fiveHour 10 % still spends), `alreadySpentThisWindowSkips` (state key == weekly.resetsAt), `codexIdleSkips` (last activity 31 min ago, no stop), `windowResetsSoonSkips` (resetsAt in 11 h 59 m), `nullExpiryChosenLast`, `noAvailableCreditSkips` (only `redeeming`), `accountChangeIgnoresOldWindowMarker` (state marker set with `autoSpendAccountId "a"`, snapshot `accountId "b"` → may spend), `expiringSoonUnder24h` (expiry now+23 h included, now+25 h excluded).
  - Executor with `FakeAppServer`: `ledgerWrittenBeforeCall` (fake inspects ledger file at call time → entry present), `finalOutcomeClearsLedger` (each of 4 outcomes), `timeoutRetriesWithSameKey` (2 timeouts then `reset`; all 3 requests carry identical `idempotencyKey` and `creditId`), `pendingLedgerEntryIsRetriedWithSameKey` (new executor instance on same ledger file → `resumePending()` sends the stored key), `secondSpendWhilePendingIsBusy`, `ledgerOlderThan24hExpires`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** `feat(core): reset-credit policy with idempotent ledger`.

---

### Task 9: Forecast

**Files:**
- Create: `Sources/LimitGuardCore/Policy/Forecast.swift`
- Test: `Tests/LimitGuardCoreTests/ForecastTests.swift`

**Interfaces:**
- Produces: `Forecast.runOut(samples: [(Date, Double)], now: Date, resetsAt: Date?) -> Date?` — least-squares slope over samples in the last 6 h (min 2 h span, ≥ 3 samples, slope > 0); samples before the latest drop of > 5 points are discarded (a reset happened); returns nil if the projected time is after `resetsAt`.

- [ ] **Step 1: Failing tests:** `linearBurnProjects` (50→56 % over 3 h → 100 % at +22 h), `tooFewSamplesNil`, `flatNil`, `afterResetUsesOnlyNewSamples`, `beyondResetsAtNil`.
- [ ] **Step 2–4:** FAIL → implement → PASS. **Step 5: Commit** `feat(core): burn-rate forecast`.

---

### Task 10: Delivery — protocol, app-server delivery, tab matcher

**Files:**
- Create: `Sources/LimitGuardCore/Delivery/{Delivery,AppServerDelivery,TabMatcher}.swift`
- Test: `Tests/LimitGuardCoreTests/DeliveryTests.swift`

**Interfaces:**
- Consumes: `AppServerClient` (proxy transport per Task 0), `SessionState`.
- Produces:
  - `struct ContinueRequest: Equatable { threadId: String; text: String; clientMessageId: UUID; tab: TabRef? }`
  - `enum DeliveryResult: Equatable { sent, refused(String), failed(String) }`
  - `protocol ContinueDelivery: Sendable { func deliver(_ request: ContinueRequest) async -> DeliveryResult }`
  - `struct AppServerDelivery: ContinueDelivery` — `thread/loaded/list` must contain `threadId` else `.refused("thread not loaded")`; then `turn/start` with `{"threadId", "input":[{"type":"text","text":…}], "clientUserMessageId": uuid}` and **no** model/effort/approval/sandbox keys (D27).
  - `DeliveryConfirmer.isConfirmed(request:session:) -> Bool` — `session.seenClientMessageIds` contains the id (app-server path) or a user message after `request` time equals the text (typing path).
  - `struct TabRef: Codable, Hashable { windowId: Int; tabIndex: Int; tty: String }`, `struct TerminalTab: Equatable { ref: TabRef; title: String; cwd: String?; codexPid: Int32?; busy: Bool }`
  - `TabMatcher.match(tabs: [TerminalTab], threads: [SessionState], loadedThreadIds: Set<String>?) -> [TabRef: String /*threadId*/]` — rules of spec §7.3; ambiguous tabs omitted. `TabMatcher.match(single:)` helper for the one-tab case.

- [ ] **Step 1: Failing tests:** `turnStartHasNoOverrides` (request params keys == `["threadId","input","clientUserMessageId"]`), `notLoadedIsRefused`, `confirmedByClientMessageId`, `oneTabOneThreadPairs`, `cwdSeparatesTwoTabs`, `ambiguousMappingReturnsNil` (two tabs same cwd, two threads same cwd → empty map).
- [ ] **Step 2–4:** FAIL → implement → PASS. **Step 5: Commit** `feat(core): continue delivery via app-server and tab matching`.

---

### Task 11: Engine (orchestration) + Terminal fallback + system services

**Files:**
- Create: `Sources/LimitGuardCore/Engine/{Engine,Clock}.swift`
- Create: `Sources/CybokronLimitGuard/Terminal/{TerminalBridge,TerminalTypingDelivery}.swift`, `Sources/CybokronLimitGuard/System/{Notifier,KeepAwake,LoginItem}.swift`
- Test: `Tests/LimitGuardCoreTests/EngineTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `protocol Clock: Sendable { var now: Date { get }; func sleep(until: Date) async throws }`; `TestClock` in tests (manual advance).
  - `protocol EngineEnvironment: Sendable { func terminalTabs() async -> [TerminalTab]; func notify(_ note: EngineNote) async; func setKeepAwake(_ on: Bool) async; func secondsSinceLastKeyEvent() -> TimeInterval; func tabShowsPicker(_ tab: TabRef) async -> Bool }`
  - `enum EngineNote: Equatable { limitReached, limitIsBack, continueCountdown(threadId: String, seconds: Int), continueSent(threadId: String), continueSkipped(threadId: String, reason: String), unconfirmed(threadId: String), loopStopped(threadId: String), resetUsed(ConsumeOutcome), resetExpiring(creditId: String, at: Date), readOnly(String), permissionMissing(String) }`
  - `@MainActor final class Engine: ObservableObject { @Published private(set) var snapshot: AccountSnapshot?; health: ProtocolHealth; sessions: [SessionState]; tabs: [TerminalTab]; nextAction: NextAction?; forecast: (fiveHour: Date?, weekly: Date?); func start(); func tick() async; func cancelNextAction(); func useReset(creditId: String) async -> SpendResult; func continueNow(threadId: String) async; func setGuarded(_ tab: TabRef, _ on: Bool); func pause(_ on: Bool) }`
  - `struct NextAction: Equatable { kind: Kind (.continueAt(Date, threadId, text), .countdown(until: Date, threadId, text), .autoSpendArmed(threshold: Int)); }`
  - Polling cadence exactly as spec §5; keep-awake on between a guarded usage-limit stop and its continue when the wait is < 6 h (D14).
  - `TerminalBridge` (AppleScript via `NSAppleScript`): `tabs() -> [TerminalTab]` (window id, tab index, tty, custom title, busy; cwd via `lsof -a -p <pid> -d cwd -Fn`; codex pid via `ps -t <tty> -o pid=,comm=`), `historyTail(_ tab:, chars: 4000) -> String`, `type(_ text: String, into tab: TabRef)` using `do script <text> in tab <i> of window id <w>` (exact form per Task 0 S1).
  - `TerminalTypingDelivery: ContinueDelivery` — re-checks the tab's tty and foreground pid, refuses when `secondsSinceLastKeyEvent() < 5` (postpone up to 5 × 30 s, then `.refused("owner typing")`), refuses when `tabShowsPicker` (strings: "Choose an option below to continue", "Turn on Daybreak"), then types.

- [ ] **Step 1: Failing tests** (Engine with `TestClock`, `FakeAppServer`, fake environment, temp dirs):
  - `happyPathContinues`: stop at T, resetsAt T+1h, gate false→true at T+1h → countdown 10 s → `turn/start` sent once with text "devam et" for a Turkish sample; `continueSent` note.
  - `recheckBeforeSendAborts`: user message appears during countdown → no `turn/start`, `continueSkipped`.
  - `cancelDuringCountdown`: `cancelNextAction()` → nothing sent, activity `continueCancelled`.
  - `unconfirmedIsNeverResent`: no client id within 2 min → `unconfirmed` note, exactly one `turn/start` after 10 more minutes.
  - `wakeRunsMissedContinueOnce`: clock jumps 3 h (sleep) past reset → one send.
  - `autoSpendThenContinue`: weekly 97 %, enabled, in use → one consume with earliest credit, re-read, then continue for a weekly stop.
  - `limitIsBackNotifiesOnce`: gate false→true → one `limitIsBack`.
  - `noticeNotAcceptedDoesNothing`: notice nil → no `turn/start`, no consume, snapshot still published.
  - `keepAwakeOnlyWhileWaiting`: on at stop, off after send.
- [ ] **Step 2–4:** FAIL → implement Engine → PASS. Implement `TerminalBridge`/`TerminalTypingDelivery`/`Notifier`/`KeepAwake` (`IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep …)`)/`LoginItem` (`SMAppService.mainApp`) in the app target (no unit tests; covered by Task 19 manual gates).
- [ ] **Step 5: Commit** `feat: engine orchestrating continue and reset flows`.

---

### Task 12: Menu-bar item and popover

**Files:**
- Create: `Sources/CybokronLimitGuard/MenuBar/{StatusItemController,PopoverView,LimitBarView,ResetCreditsView,GuardedTabsView,NextActionView}.swift`, `Sources/CybokronLimitGuard/App/{AppDelegate,InstanceHandoff}.swift` (InstanceHandoff ported from Dock Groups, URL scheme `cybokronlimitguard://`)
- Modify: `Resources/en.lproj/Localizable.strings` (+ tr placeholders filled in Task 17)
- Test: `Tests/LimitGuardCoreTests/PresentationTests.swift` for pure formatters in Core

**Interfaces:**
- Consumes: `Engine` published state.
- Produces (Core, pure): `MenuBarText.make(snapshot:showPercent:) -> (text: String?, level: Level (.normal/.warning/.critical))` — picks the window with the higher `usedPercent`, labels `5h`/`W`, warning ≥ 80, critical ≥ 95 or gate false; `ResetsInFormatter.string(until: Date, now: Date, locale: Locale) -> String` ("3 h 42 m", "5 d 21 h"); `CreditPresentation.rows(credits:now:) -> [CreditRow]` (expiring < 24 h first, `isExpiringSoon`).

- [ ] **Step 1: Failing tests:** `menuBarShowsCriticalWindow` (5h 100, W 59 → "5h 100%", `.critical`), `menuBarHiddenWhenOff`, `resetsInFormats` (13 320 s → "3 h 42 m" en; tr equivalent from strings), `expiringCreditFirst`.
- [ ] **Step 2–4:** FAIL → implement formatters → PASS. Build the popover in the order of spec §4.2 (status line incl. §4.4 states, 5-hour bar + forecast line, weekly bar + forecast, next action + Cancel, Usage limit resets with "N available" chip and per-row **Use Reset** → `NSAlert` confirm → `engine.useReset`, Guarded tabs with checkboxes + "waiting (not guarded)" + **Continue now**, footer). Visual style copied from Dock Groups' `PanelPalette`.
- [ ] **Step 5:** `scripts/build-app.sh` and check the popover against live data (read-only; do not press Use Reset).
- [ ] **Step 6: Commit** `feat: menu-bar item and popover`.

---

### Task 13: Legal notice and Diagnostics

**Files:**
- Create: `Sources/CybokronLimitGuard/Windows/LegalNoticeWindow.swift`, `Sources/CybokronLimitGuard/System/Diagnostics.swift`, `Sources/LimitGuardCore/Policy/Notice.swift`
- Test: `Tests/LimitGuardCoreTests/NoticeTests.swift`

**Interfaces:**
- Produces: `enum Notice { static let currentVersion = 1; static func mustShow(settings: Settings) -> Bool }`; notice text keys `notice.title`, `notice.body` with the exact English text of spec §4.3.1; `struct DiagnosticItem { title: String; status: .ok/.warning/.failed; fix: String? }`; `Diagnostics.run() async -> [DiagnosticItem]` (checks of spec §4.3.2; approval policy read from `~/.codex/config.toml` key `approval_policy`, warn unless `"never"`).

- [ ] **Step 1: Failing tests:** `noticeShownWhenNeverAccepted`, `noticeShownAgainOnVersionBump` (accepted 0), `noticeHiddenWhenCurrent`, `noticeTextMatchesSpec` (en string equals spec text verbatim).
- [ ] **Step 2–4:** FAIL → implement → PASS. Window: modal at launch, buttons "I understand" (stores version + date) / "Quit"; reachable from About and Settings → General.
- [ ] **Step 5: Commit** `feat: first-run legal notice and diagnostics`.

---

### Task 14: Settings window

**Files:**
- Create: `Sources/CybokronLimitGuard/Settings/{SettingsWindowController,GeneralSettingsView,ContinueSettingsView,ResetsSettingsView,NotificationsSettingsView}.swift`

**Interfaces:**
- Consumes: `Settings` store, `LoginItem`, `Diagnostics`, `Notice`.
- Produces: tabs General · Continue · Resets · Notifications · Updates · Changelog · Support (last three from Task 16). Controls and ranges exactly as spec §10 and Global Constraints: countdown 0–60 s, max tries 1–10, min gap minutes, threshold 80–99 % with the text "Use a reset credit when the weekly limit is almost used up" (default off), continue-text table add/remove, fallback text, notification toggles per `EngineNote` kind, language picker (writes `AppleLanguages` for the app domain; restart prompt), Codex path override with "Reveal"/"Reset", "Guard new Codex tabs automatically", "Show legal notice", "Run Diagnostics".

- [ ] **Step 1:** Build views; bind to the settings store; persist on change.
- [ ] **Step 2:** `scripts/test.sh` (Localization test catches missing keys) → PASS; build app, toggle every control, quit and relaunch → values kept.
- [ ] **Step 3: Commit** `feat: settings window`.

---

### Task 15: Activity and usage chart windows

**Files:**
- Create: `Sources/CybokronLimitGuard/Windows/{ActivityWindow,UsageChartWindow}.swift`
- Test: `Tests/LimitGuardCoreTests/ChartDataTests.swift`

**Interfaces:**
- Produces (Core): `ChartData.daily(_ report: UsageReport, days: Int /*7|30|90*/, today: String) -> [DailyUsage]` (fills missing days with 0); `ChartData.limitHistory(_ samples: [UsageSample], days: Int) -> [UsageSample]`.

- [ ] **Step 1: Failing tests:** `fillsMissingDays`, `clipsToRange`.
- [ ] **Step 2–4:** FAIL → implement → PASS. Activity window: table (time, kind, tab, thread short id, text, detail) + Copy + Clear. Chart window: Swift Charts bars (daily tokens, 7/30/90 picker, summary line peak/streak), lines for 5-hour and weekly % history, forecast caption; only history chart when `daily == nil`.
- [ ] **Step 5: Commit** `feat: activity log and usage chart windows`.

---

### Task 16: About, updates + downgrade, changelog

**Files:**
- Create: `Sources/CybokronLimitGuard/About/*` (copy from Dock Groups; add this repo to `AboutData.projects`, change `issuesURL`), `Sources/LimitGuardCore/Updates/*` and `Sources/LimitGuardCore/Changelog/*` (copy from Dock Groups `DockGroupsCore/Updates`, `/Changelog`), `Sources/CybokronLimitGuard/Updates/*`, `Sources/CybokronLimitGuard/Settings/{UpdatesSettingsView,OtherVersionsView,ChangelogSettingsView,SupportSettingsView}.swift`
- Test: copy Dock Groups' `UpdateInstallerTests`, `UpdateSignatureTests`, `ReleaseFeed`/`ReleaseHistory`/`Changelog` tests, adapted.

**Interfaces:**
- Produces: repo slug `ercanatay/cybokron-limit-guard`, DMG name pattern `Cybokron-Limit-Guard-<version>-universal.dmg`, `ReleaseHistory.minimumSecurityVersion = 0.1.0`; downgrade calls `makePreDowngradeCopies` (Task 5) before installing an older version.

- [ ] **Step 1:** Copy files, rename module references (`DockGroupsCore` → `LimitGuardCore`), bundle id, repo slug, strings (new L10n keys).
- [ ] **Step 2: Run** the copied tests → PASS (fix renames only; no behaviour changes).
- [ ] **Step 3:** Build; About window shows all sections; Settings → Changelog lists (empty until first release — shows the empty state).
- [ ] **Step 4: Commit** `feat: about, updates with downgrade, changelog (from Dock Groups)`.

---

### Task 17: Turkish translations, icon, documentation

**Files:**
- Modify: `Resources/tr.lproj/Localizable.strings`
- Create: `Resources/Assets.xcassets/AppIcon.appiconset/*` (via `scripts/generate-app-icon.swift`, new Cybokron-style shield + gauge glyph), `README.md` (features, screenshots, legal notice text, privacy §4.6, install, build), `SECURITY.md`, `CONTRIBUTING.md`, `AGENTS.md`, `CHANGELOG.md` `[0.1.0]`, `docs/screenshots/`

- [ ] **Step 1:** Export all en keys missing a reviewed tr value to a chunk file; run `~/.claude/scripts/haiku-translate.sh tr < en-chunk > tr-chunk`; review every line (meaning, "devam et"/"sıfırlama hakkı" terminology matching the ChatGPT Turkish UI: "Kullanım limiti sıfırlamaları", "Tam sıfırlama", "Sıfırlamayı kullan", "Bitiş"); merge.
- [ ] **Step 2: Run** `scripts/test.sh --filter Localization` → PASS; `plutil -lint Resources/*/Localizable.strings` → OK.
- [ ] **Step 3:** Generate icon, write docs, take screenshots (dark theme, cropped like Dock Groups).
- [ ] **Step 4: Commit** `docs: Turkish strings, icon, README and project docs`.

---

### Task 18: Release v0.1.0

**Files:**
- Modify: `project.yml` (versions), `CHANGELOG.md`

- [ ] **Step 1:** Set repo secrets/variables for this repo with the owner (same six Apple secrets as Dock Groups via `gh secret set -R ercanatay/cybokron-limit-guard`, `NOTARIZE_ENABLED=true`, `release` environment with required reviewer) — owner confirms before each `gh secret set`.
- [ ] **Step 2:** `scripts/check-version.sh v0.1.0` → OK; `scripts/test.sh` → all PASS; `UNIVERSAL=1 scripts/build-app.sh release` → OK.
- [ ] **Step 3:** Tag `v0.1.0`, push; approve the `release` environment; CI produces a notarized DMG draft. Verify: `xcrun stapler validate`, `spctl -a -vv -t install <dmg>` → "Notarized Developer ID".
- [ ] **Step 4:** Ask the owner before publishing the draft (`gh release edit v0.1.0 --draft=false`).

---

### Task 19: Manual acceptance gates (owner + implementer, real machine)

Record results in `docs/design/limit-guard-spike.md` § Acceptance. Never press **Use Reset** or enable auto-spend during these unless the owner explicitly asks at that moment.

- [ ] Legal notice blocks automation until accepted; re-shows after a `noticeVersion` bump (debug build).
- [ ] Popover numbers match ChatGPT's usage page (5-hour, weekly, credits, expiry dates).
- [ ] Guarded tab chosen → at a real 5-hour stop, countdown appears and "devam et" is delivered into that tab once; unguarded tab gets nothing and shows **Continue now**.
- [ ] Finished task → nothing sent. Owner types during countdown → nothing sent.
- [ ] Mac sleeps through the reset → one continue after wake (keep-awake off case).
- [ ] Automation permission denied → "Permission needed" row (fallback path only).
- [ ] Diagnostics shows the approval-policy warning when `approval_policy` is interactive.
- [ ] Update check, Other Versions… downgrade to a test build keeps `*.pre-downgrade-*.json` copies.
- [ ] Turkish UI end to end (system language and in-app override).
