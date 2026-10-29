# Cybokron Limit Guard — Phase 1 design (Codex CLI in Terminal.app)

Status: DRAFT for owner review · 2026-10-29 · target release v0.1.0

## 1. Intent

Codex CLI stops mid-task when the account hits its usage limit ("Usage limit reached…" /
"Your workspace is out of credits…"). Today the owner has to notice, wait for the 5-hour
window to reset, and type "devam et" by hand. Separately, the weekly limit can run out in the
middle of a long task even though the account holds unused "Full reset (Weekly + 5 hr)"
credits that later expire unused.

Cybokron Limit Guard is a small, open-source macOS menu-bar app that:

1. Shows Codex usage clearly (5-hour %, weekly %, reset times, reset credits with expiry dates).
2. When a Codex turn in Terminal.app was cut by the usage limit, waits until usage is allowed
   again and types a "continue" message, in the conversation's language, into that exact tab.
3. If the owner allows it, spends **one** reset credit when the weekly limit is about to run out,
   so the task is not interrupted.
4. Lets the owner spend a specific reset credit manually, right now, from the menu.
5. Shows a legal notice on first run; nothing automatic happens until it is accepted.

It must stay simple and understandable. It is built for the owner's own workflow first; later
phases extend it to other terminals/IDEs and other agents (§14).

## 2. Goals, non-goals, anti-goals

**Goals (Phase 1)**
- Codex CLI (TUI, `originator = codex-tui`) running in **Terminal.app** only.
- Read every account number through Codex's own local API (`codex app-server`), never by
  scraping the screen and never by reading credentials.
- Never send "continue" to a task that finished normally.
- Never spend a reset credit unless the owner enabled it (auto) or pressed the button (manual).
- English + Turkish UI. Same look and feel as Cybokron Dock Groups (Settings, About, Changelog,
  updates, downgrade).

**Non-goals (Phase 1)**
- iTerm2, Ghostty, Warp, VS Code/Cursor terminals, the Codex desktop app, Claude Code, OpenCode.
- Multiple Codex accounts at once (the app follows whatever account `codex` is logged into).
- Buying credits, changing plans, or anything on chatgpt.com.

**Anti-goals (a failure even if it "works")**
- Typing into the wrong tab, or into a tab where the owner is mid-sentence.
- Spending two credits where one was intended, or spending one without permission.
- A continue loop that burns a 5-hour window on retries.
- Guessing usage from percentages and acting on the guess.

## 3. Facts the design rests on (verified 2026-10-29, codex-cli 0.165.0-alpha.1.2)

- `codex` on PATH is a shell wrapper → `/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`.
- `codex app-server` speaks newline-delimited JSON-RPC over stdio. Handshake:
  `{"id":1,"method":"initialize","params":{"clientInfo":{"name":…,"title":null,"version":…},"capabilities":null}}`
  then notification `{"method":"initialized"}`. Protocol is marked **experimental**.
- `account/rateLimits/read` (no params) → `GetAccountRateLimitsResponse`:
  - `ordinaryUsageAllowed: bool|null` — schema: *"Null means unavailable; clients must not infer
    recovery from percentages or reset times."*
  - `rateLimits.primary` = 5-hour window `{usedPercent, windowDurationMins: 300, resetsAt}`;
    `rateLimits.secondary` = weekly window (`10080` min). `planType`, `rateLimitReachedType`
    (seen: `workspace_owner_credits_depleted`).
  - `rateLimitResetCredits: {availableCount, credits: [{id, resetType: "codexRateLimits",
    status: available|redeeming|redeemed|unknown, grantedAt, expiresAt|null, title, description}] | null}`.
    Live: 2 credits "Full reset (Weekly + 5 hr)", expiring 29 Oct 22:29 and 7 Nov 02:55 GMT+3.
- `account/rateLimitResetCredit/consume` params `{idempotencyKey (UUID, reuse on retry),
  creditId?}` → `{outcome: reset|nothingToReset|noCredit|alreadyRedeemed}`. The binary contains
  "rate limit reset consume timed out" — timeouts happen.
- `account/usage/read` → `dailyUsageBuckets: [{startDate: "YYYY-MM-DD", tokens}]` (216 days live)
  + `summary {lifetimeTokens, peakDailyTokens, currentStreakDays, …}`.
- Session rollouts: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. A rollout keeps being
  appended for days (resumed sessions) — judge activity by last event time, not file name.
  - First line `session_meta` (`id`, `cwd`, `originator`, `cli_version`).
  - Each turn ends with `event_msg` / `task_complete` `{turn_id, error}`. Last 30 days:
    162 × `error = null` (finished), 42 × `error.codex_error_info = "usage_limit_exceeded"`,
    2 × `server_overloaded`.
  - User messages are `response_item` `message` `role: user` (includes injected boilerplate such
    as environment context / AGENTS.md instructions).
- `~/.codex/state_5.sqlite` table `threads` (`id, rollout_path, cwd, originator, updated_at_ms,
  archived, …`) indexes the rollouts. File names carry a schema number that may change.
- The Terminal TUI process (`tty ttys003`) does **not** write the rollout itself: it talks to a
  shared app-server daemon (`~/.codex/packages/app-server-daemon/…`, tty `??`). So
  *process → thread* is not directly observable; see §7.3 and Spike S2.
- The ChatGPT/Codex desktop app runs its own `codex` processes with no tty — ignore them.

## 4. The app at a glance

Menu-bar only (`LSUIElement`), Swift + SwiftUI + AppKit, macOS 14+, **no third-party
dependencies, no SPM packages** (same rule as Dock Groups). Not sandboxed (must launch `codex`
and read `~/.codex`). Hardened runtime, Developer ID, notarized.

Bundle id `com.cybokron.limitguard`, repo `github.com/ercanatay/cybokron-limit-guard` (public,
MIT). Two targets like Dock Groups: `LimitGuardCore` (pure logic, fully unit-tested) and
`CybokronLimitGuard` (UI/AppKit).

### 4.1 Menu-bar item
- Icon + optional text (Setting "Show percentage in menu bar", default **on**).
  Text shows the more critical window, e.g. `5h 100%` or `W 97%`; colour orange ≥ 80 %,
  red ≥ 95 % or when `ordinaryUsageAllowed == false`. A small pause glyph when paused.

### 4.2 Popover (click)
Top to bottom:
1. **Status line**: "Watching 1 Codex session" / "Paused" / "Read-only: Codex protocol changed".
2. **5-hour limit** bar: `100 % used · resets in 3 h 42 m (18:15)`.
3. **Weekly limit** bar: `59 % used · resets in 5 d 21 h (Tue 4 Nov 10:30)`.
4. **Next action** (only when one is scheduled): "At 18:15 type 'devam et' into Terminal —
   `~/project` (ttys003)" with **[Cancel]**. Also the reset-credit plan if armed
   ("Will use 1 reset when weekly reaches 97 %").
5. **Usage limit resets** section (mirrors the ChatGPT screen the owner shared):
   chip "2 available"; one row per credit: title (e.g. "Full reset (Weekly + 5 hr)"),
   "Expires 29 Oct 22:29 GMT+3", button **[Use Reset]**. Credits expiring in < 24 h are sorted
   first and tinted orange with "expires today/tomorrow". Credit `title` is shown as the backend
   sends it (not translated); dates use the system locale/time zone.
6. Footer: **Pause/Resume**, Activity…, Usage chart…, Settings…, About, Quit.

Manual **[Use Reset]** → confirmation alert ("Use this reset now? This can't be undone.") →
consume protocol (§8) with that exact `creditId` → result inline ("Usage reset" /
"Nothing to reset right now" / "No resets available" / "Already used") → re-read limits.
If after a successful manual reset a Codex session is waiting on a usage-limit stop, the
normal continue flow (§7) runs immediately (still with its safety checks and countdown).

### 4.3 Windows
- **Settings** (tabs): General · Continue · Resets · Notifications · Updates · Changelog ·
  Support. (§10)
- **Activity** — last 100 events (§11).
- **Usage chart** — daily consumption (§12).
- **About** — same content/structure as Dock Groups' About (`AboutData`: website
  cybokron.com, source/license/changelog links, Buy Me a Coffee / Ko-fi / GitHub Sponsors
  `ercanatay`, the four books, other open-source projects incl. cybokron-dock-groups, Medium
  blogs, social profiles). Add this repo to the projects list; keep the copy in sync by
  copying the files, not by sharing a package.

## 5. Architecture

```
LimitGuardCore
  CodexLocator          resolve codex binary (PATH, ChatGPT.app path, user override); read --version
  AppServerClient       spawn `codex app-server`, JSON-RPC over stdio, timeouts, restart
  CodexAccountService   rateLimits/read, usage/read, consume — tolerant decoding → AccountSnapshot
  ProtocolGuard         decides "full" vs "read-only" mode from decode results
  SessionScanner        state_5.sqlite (read-only) + rollout tail parsing → SessionState
  TurnOutcomeParser     last task_complete / user message / language sample
  LanguageDetector      NaturalLanguage (NLLanguageRecognizer) → continue text
  ContinuePolicy        pure decision: should we type now? (§7)
  ResetPolicy           pure decision: should we spend a credit now? (§8)
  ResetLedger           pending-consume journal on disk (idempotency)
  ActivityLog, UsageHistory, Settings, Store (JSON files, schemaVersion)
  Updates/*, Changelog/*  copied from Dock Groups
CybokronLimitGuard
  TerminalBridge        Apple Events to Terminal.app: list tabs (tty, busy, processes,
                        history), type text into a tab           ← "where" (Terminal)
  AgentAdapter protocol ← "what" (Codex); Phase 1 has CodexAdapter only
  Scheduler             timers, sleep/wake, power assertion
  MenuBar/, Popover/, Settings/, Activity/, Chart/, About/, Updates/
```

`AgentAdapter` (Codex) and `HostAdapter` (Terminal) are protocols from day one so later phases
add implementations, not rewrites. Phase 1 ships exactly one of each.

Polling: limits every **5 min** normally; every **1 min** when a window is ≥ 90 % or a
continue is pending; from `resetsAt` onward every 30 s for 5 min, then back-off (1, 2, 5 min)
up to 60 min. Session scan: file-system events on `~/.codex/sessions` + `state_5.sqlite`
(FSEvents), with a 30 s fallback timer. One long-lived `app-server` child; restart on crash with
back-off; shut down on quit.

### 4.3.1 First-run legal notice (D23)
Before anything automatic can run, a modal window shows a notice the owner must accept
("I understand" / "Quit"). Until accepted, the app only displays usage (read-only). Text
(EN; TR translated by the normal i18n flow, reviewed):

> **Before you use Cybokron Limit Guard**
> This is an independent, open-source tool. It is not made, endorsed or supported by OpenAI or
> any other AI platform. It acts on your behalf: it can send messages into your Codex sessions
> and, only if you allow it, redeem your usage-limit reset credits. Automated use, or a fault in
> this tool, may conflict with the usage policies of your AI platform account, which may then
> apply restrictions, limits or suspensions to your account. You use this tool at your own
> risk; the software is provided "as is", without warranty of any kind (MIT License). Review
> your platform's terms before enabling automatic actions.

The accepted notice version and date are stored in `settings.json`; if the text changes
(`noticeVersion` bump) it is shown again. The notice is also reachable from About and from
Settings → General, and is repeated in README.

### 4.3.2 Diagnostics / Doctor (D26)
Settings → General → **Run Diagnostics**, and automatically when something fails. Checks with
✓/⚠/✗ and a one-line fix: codex found + version (and whether it is newer than the last tested
version), signed in with ChatGPT, app-server daemon reachable, `rateLimits/read` decodes,
Terminal automation permission (fallback path), notifications allowed, **approval policy**:
warns when Codex's `approval_policy` is interactive ("an unattended continue will stop at the
first approval prompt"), and Keep-awake assertion state. Copy-to-clipboard report (no secrets).

### 4.4 Empty and error states
Shown in the popover status line with a one-line fix: Codex not found (link to set the path) ·
Codex not signed in with ChatGPT (`codex login`) · app-server failed to start (retrying) ·
Terminal permission missing · notifications not allowed · no Codex tab open. The active
account's plan (`planType`) is shown small in the footer; if the account changes, per-account
state (auto-spend marker, ledger) is not reused for the new account.

### 4.5 Other app basics
- App icon in the Cybokron style (new artwork), light/dark aware popover, keyboard accessible.
- Single instance (a second launch hands over and quits, as Dock Groups' InstanceHandoff).
- Notification permission (`UNUserNotificationCenter`) asked on first launch with an
  explanation; the app works without it (popover only).

### 4.6 Privacy
Everything stays on the Mac. The app reads Codex's local session files only to detect stops and
the conversation language; it never copies conversation text into its own files (the activity
log stores only the continue text it typed), never reads `auth.json`, and sends nothing
anywhere except Codex's own app-server and GitHub (update check / changelog). No analytics.
README and SECURITY.md state this.

## 6. Protocol safety ("read-only mode")

The protocol is experimental and changes between Codex releases.
- Decode tolerantly (unknown fields ignored, unknown enum values → `.unknown`).
- If a field the **actions** depend on is missing/undecodable (`ordinaryUsageAllowed`, window
  shape, credit `id`/`status`, consume `outcome`, `task_complete` shape), the app enters
  **read-only mode**: it keeps showing whatever it can, never types, never spends, shows a banner
  "Codex changed how it reports usage — automatic actions are paused", and logs the codex version.
- Record `codex --version` in every activity entry that acts.
- Never read `~/.codex/auth.json` or any credential; every account call goes through
  `codex app-server`.

## 7. Auto-continue (5-hour or any usage-limit stop)

### 7.1 When is a session "waiting on the limit"?
A Codex TUI session is **eligible** when all hold:
- its thread's last `task_complete` has `error.codex_error_info == "usage_limit_exceeded"`;
- no `user` message and no newer turn started after that `task_complete` (owner hasn't typed);
- the event is less than **24 h** old (older stops are ignored) — for a weekly-limit stop the
  limit is `secondary.resetsAt + 1 h` instead (D14);
- the thread is mapped to exactly one Terminal tab (§7.3).

Finished turns (`error == null`), other errors (`server_overloaded`, …) and aborted turns are
never continued.

### 7.2 When to type
1. Wait until `primary.resetsAt` (or `secondary.resetsAt` if the weekly window is the one at
   100 %). This only schedules the first check.
2. **Gate: `ordinaryUsageAllowed == true`** from a fresh `rateLimits/read` (< 30 s old).
   `false` → keep polling with back-off; `null` / decode failure → do nothing. Percentages and
   `resetsAt` never open the gate on their own. If still `false` 60 min after `resetsAt`, notify
   once ("Codex still reports the limit as reached") and keep waiting quietly.
3. **Countdown**: notification + popover row "Typing 'devam et' into Terminal in 10 s —
   [Cancel]". Default 10 s, setting 0–60 s.
4. **Re-check right before typing** (all must still hold): session still eligible (re-read the
   rollout tail), tab still exists with the same tty, the tab's process is still the same Codex
   TUI pid, app not paused, loop guard not exhausted.
5. Type the continue text and submit (§9). Log it.
6. **Verify**: within 2 min the rollout must show a new user message / turn start. If not,
   log "continue not observed" and count it as a failed attempt.

### 7.3 Which tab

**The owner chooses which Terminal windows/tabs are guarded (D19).** Nothing is guarded by
default. The popover has a **Guarded tabs** section listing every open Terminal tab that runs a
Codex TUI (window/tab title, working directory, tty, short thread title when known) with a
checkbox each; several can be ticked. Auto-continue only ever types into a ticked tab; an
unticked tab that stops on the limit is shown as "waiting (not guarded)" with a one-click
**Continue now** button. The choice is kept per tab (Terminal tab identity = window id + tab
index + tty) for as long as the tab lives; a closed tab drops out. Setting "Guard new Codex
tabs automatically" (default **off**).

Mapping a guarded tab to its thread:
- Candidate tabs: **ticked** Terminal tabs whose `tty` has a foreground `codex` TUI process
  (`ps -t <tty>`; the CodexCLI binary; ignore processes with tty `??`).
- Candidate threads: eligible threads with `originator == codex-tui`.
- Mapping (to be confirmed by Spike S2), in order:
  1. If exactly one candidate tab and exactly one eligible thread → pair them.
  2. Otherwise match by evidence: thread `cwd` == process cwd, **and** the tab's visible
     history contains the limit message and/or the tail of the thread's last agent message.
  3. Still ambiguous → do **not** type; notify "Several Codex tabs are waiting — continue them
     by hand" and show them in the popover.

### 7.4 Loop guard (settings)
- Max **3** continues per thread in a row (1–10). Counter resets when a turn in that thread ends
  with `error == null`, or when the owner types in it.
- At least **2 min** between continues to the same thread.
- A continue followed by another `usage_limit_exceeded` within 10 min counts against the limit.
- Limit reached → stop for that thread, notify "Stopped after 3 tries", log it.
- **Runaway brake (D25):** 3 auto-continued turns in a row that each finish in < 60 s also stop
  the thread (likely a no-progress loop).

### 7.5 Continue text & language
- Language sample: the last 3 real user messages in the thread, ignoring injected blocks
  (`<environment_context>`, `<user_instructions>`, AGENTS.md content, anything starting with
  `<` tags, messages > 4000 chars), trimmed to 1000 chars.
- `NLLanguageRecognizer` dominant language with confidence ≥ 0.6, else fallback.
- Built-in texts: `tr` "devam et", `en` "continue". Settings show an editable table
  (language code → text) where the owner can add more (de "weiter", es "continúa", …).
  Unknown/low-confidence → fallback text (default "continue", editable).

## 8. Reset credits

### 8.1 Automatic (off by default)
Setting **"Use a reset credit when the weekly limit is almost used up"** (default **off**),
threshold **97 % used** (= 3 % left; editable 80–99).
Spend one credit only when all hold:
- setting on, not paused, not read-only;
- fresh read shows `secondary.usedPercent ≥ threshold`, `availableCount ≥ 1`, at least one
  credit with `status == available`;
- the 5-hour window state does **not** matter (spend even if the 5-hour limit is not reached);
- no automatic spend has happened yet in this weekly window (key = `secondary.resetsAt`):
  **max one automatic spend per weekly window**;
- no pending consume in the ledger;
- **Codex is in use**: a Codex TUI turn ran in the last 30 min, or a session is waiting on a
  usage-limit stop (D15);
- the weekly window does **not** reset on its own within the next **12 h** (D15).
Choice of credit: the available one with the **earliest `expiresAt`** (null = never expires,
chosen last), passed explicitly as `creditId`.
After the call, re-read limits. If weekly is still ≥ threshold after an `outcome == reset`, notify
and do not try again this window.

### 8.2 Manual
Popover button (§4.2). Always allowed (also when the auto setting is off), still goes through
the ledger, still confirms.

### 8.3 Consume protocol (both paths)
1. Write a ledger entry `{idempotencyKey: UUID, creditId, reason: auto|manual, createdAt}` to
   `reset-ledger.json` **before** calling.
2. Call consume (timeout 30 s). On timeout / crash / app-server restart: retry with the **same**
   key and creditId (up to 3 tries over ~5 min; also on next launch).
3. A final outcome (`reset`, `nothingToReset`, `noCredit`, `alreadyRedeemed`) clears the entry and
   is logged. These outcomes are never retried.
4. Ledger entries older than 24 h without an outcome: clear, log "unknown result", notify.

### 8.4 Expiry reminders
Credits with `expiresAt` < 24 h away: highlighted in the popover and one notification per
credit ("A reset credit expires today at 22:29"). No automatic spending because of expiry.

## 9. Delivering the continue message

### 9.0 Preferred path: Codex's own app-server (Spike S5)
The Terminal TUI is a client of the shared app-server daemon. `codex app-server proxy`
connects to that same daemon over its control socket; `thread/loaded/list` lists the threads
currently loaded by clients and `turn/start {threadId, input, clientUserMessageId}` starts a
turn in a given thread. If S5 confirms that a turn started this way appears and runs in the
owner's Terminal tab, this is the **primary delivery path**:
- exact thread targeting by `threadId` (no tab guessing, no keystrokes, no draft clobbering,
  no risk of hitting Enter on a picker);
- no Automation / Accessibility permission needed;
- the turn keeps the thread's model, effort, approval and sandbox settings — the app never
  passes `model`/`effort`/`approvalPolicy`/`sandboxPolicy` overrides (D27).
Guarded-tab selection (§7.3) still decides *which* sessions may be continued; the tab ↔ thread
link then only needs to be known for display. Keystroke typing (§9.1) remains as fallback when
S5 fails or the daemon isn't reachable.

### 9.0.1 Delivery confirmation (D24)
Every continue carries a fresh `clientUserMessageId` (UUID, stored in `state.json` before
sending). The app confirms delivery by finding that id (path 9.0) or a new user message/turn
(path 9.1) in the thread within 2 min. Unconfirmed → marked "unconfirmed" in Activity and
**never re-sent automatically**; the owner gets a notification with a "Send again" button.

## 9.1 Fallback: typing into Terminal.app

Default mechanism (to be confirmed by Spike S1): Apple Events to Terminal —
`do script "<text>" in <tab>` with the tab addressed explicitly (`do script` without `in` opens
a new window — never do that). Fallback if S1 shows the TUI treats it as a newline/paste and
does not submit: bring the tab's window front, select the tab, send the text and Return via
CGEvent (needs Accessibility permission), then restore the previous front app.

Rules:
- Never type into a tab whose foreground process is not the mapped Codex pid.
- **Never type into an open Codex picker.** Codex 0.165 contains an interactive screen
  "Usage limit reached — Your included usage is exhausted. Choose an option below to continue."
  and a "Turn on Daybreak for your next request?" prompt. If the tab's visible text shows any
  such selection screen (or anything other than the normal composer), Enter would pick an
  option: skip, notify, log. Spike S1 records exactly what the screen looks like after a stop.
- Never steal focus unless the fallback is in use; if the owner is actively typing (last key
  event < 5 s, via `CGEventSourceSecondsSinceLastEventType`) postpone by 30 s (max 5 times),
  then **skip and notify** (D16). Whenever the app cannot be sure the Codex composer is empty, it
  does not type.
- Permissions: `NSAppleEventsUsageDescription` + `com.apple.security.automation.apple-events`
  entitlement (hardened runtime); Accessibility only if the fallback is needed. The app explains
  each permission before macOS asks, and the popover shows a "Permission needed" row if denied.

## 10. Settings

General: Launch at login (`SMAppService.mainApp`, default on) · Show % in menu bar (on) ·
Keep Mac awake while waiting for a reset (on; `IOPMAssertion` *PreventUserIdleSystemSleep*,
only between a usage-limit stop and the continue; display may sleep) · Codex path (auto,
override) · Language (System / English / Türkçe).
Continue: Auto-continue (on) · countdown (10 s) · max tries (3) · min gap (2 min) ·
language → text table · fallback text.
Resets: Auto-use when weekly ≥ threshold (**off**) · threshold (97 %) · expiry reminders (on).
Notifications: each kind on/off — limit reached, continue sent, continue skipped/stopped, reset
used, reset expiring, read-only mode, permission missing.
Updates: as Dock Groups (automatic check on launch + every 6 h, sha256-verified DMG install,
"Other Versions…" downgrade with pre-downgrade copy of settings/state files).
Changelog: as Dock Groups (GitHub releases list, cached with ETag, offline copy).
Support: as Dock Groups.

Pause/Resume (popover + menu): pauses all automatic typing and spending; reading continues.

Sleep/wake: on wake, re-read everything; a missed continue runs through the normal flow
(countdown included) if still eligible (same age rules as §7.1).

## 11. Activity log
`activity.json`, last 100 entries: time, kind (limitReached, continueScheduled, continueSent,
continueCancelled, continueSkipped(reason), loopGuardStop, resetUsed(outcome, creditId,
auto|manual), resetExpiring, readOnly, permissionDenied, error), tab/tty, thread id (short),
text typed, codex version. Window with a table and "Copy" / "Clear".

## 12. Usage chart
Window with Swift Charts:
- **Daily tokens**: bars from `account/usage/read` `dailyUsageBuckets`, last 30 days (toggle
  7/30/90), summary line (peak day, streak).
- **Limit history**: lines for 5-hour % and weekly % from the app's own snapshots
  (`usage-history.json`, one sample per poll, kept 30 days, ≤ 1 sample/min).
If `dailyUsageBuckets` is null, only the limit-history chart is shown.

**Forecast (D28):** from the last 2–6 h of samples the app estimates the burn rate of each window
and shows "At this pace the weekly limit runs out ~Fri 14:00" (popover under the weekly bar and in
the chart window). Shown only with ≥ 3 samples and a positive rate; hidden after a reset.

**"Limit is back" (D29):** when `ordinaryUsageAllowed` flips from false to true, a notification
fires (setting, default on) — also when auto-continue is off or no tab is guarded.

## 13. Data, files, release

`~/Library/Application Support/Cybokron Limit Guard/`: `settings.json`, `state.json` (loop
counters, per-window auto-spend marker, scheduled action), `reset-ledger.json`,
`activity.json`, `usage-history.json`, `changelog-cache.json`. Each has `schemaVersion`;
newer schema → read-only + alert; downgrade copies them to `*.pre-downgrade-<ts>.json`.

Release pipeline copied from Dock Groups: xcodegen `project.yml`, `scripts/build-app.sh`,
`make-dmg.sh`, `notarize.sh`, `check-version.sh`, `release-notes.sh`, CI on `macos-26`,
`v*` tag → `release` environment approval → notarized universal DMG → **draft** release
(published only after owner OK). CFBundleVersion = major*10000+minor*100+patch. CHANGELOG.md
(Keep a Changelog). README with screenshots, SECURITY.md, CONTRIBUTING.md, AGENTS.md.
The organisation name behind the signing team never appears in the repo, commits or release
text. Commit messages and docs in English.

i18n: `Resources/en.lproj` + `tr.lproj` `Localizable.strings`, `L10n.swift`, a test that
enforces equal keys/placeholders. Turkish strings are produced by Haiku (one call per language,
`~/.claude/scripts/haiku-translate.sh`; if the script fails, a Haiku subagent per language
kept under 100K tokens) and reviewed by the main model before merging.

Tests: Core logic is pure and covered by unit tests with fixture JSON (real-shaped rollouts and
app-server replies). **The real consume RPC is never called in tests or development**; a
`FakeAppServer` drives all spend paths. A DEBUG-only "simulate limit stop" builds a fixture
session for UI testing.

## 14. Later phases (not in this spec)
P1.5 (right after v0.1.0 ships): landing page on cybokron.com (`/limit-guard/`, `/tr/limit-guard/`)
in **English and Turkish only**, same pattern as the Dock Groups page (runbook: `cybokron-site`
skill), download link to the latest GitHub release. Other languages later.
P2: iTerm2 / Ghostty / VS Code & Cursor terminals (HostAdapter). P3: Codex desktop app.
P4: Claude Code, OpenCode (AgentAdapter). P5: multiple accounts.
Later candidates (from research, not scheduled): `/goal` threads in `usageLimited` state;
phone notifications (ntfy / Pushover); optional continue after connection/overload errors
(default off); task chains "until done" with a stop phrase. P6: landing page in the other
cybokron.com languages.

## 14.1 Prior art and research (2026-10-29)
GitHub issues openai/codex #21073 (auto-resume), #34188, #28931 (goal), #28963/#29618 (reset
credits in app), #21003/#31109 (reset countdown). Tools: Agent Auto-Continue (menu bar,
app-server delivery, delivery ids, runaway pause), lutzkind/codex-auto-resume (`codex exec
resume`, `usage_limit_exceeded` detection, 24 h cut-off), cirosantilli/codex-continue (expect
wrapper), codex-reset (npm, credit list/redeem), LimitBreak (Claude), many read-only menu-bar
monitors. X/Twitter (via Grok, unverified): biggest pains are mid-task cut-offs and typing
"continue"; credits expiring unnoticed; credits redeemed right before a platform-wide reset
being wasted; unattended loops doing damage; approvals blocking overnight runs; ToS worries.
Our differentiators: auto-continue + credit management + loop guards in one native app.

## 15. Spikes before coding (throwaway, results go in `docs/design/limit-guard-spike.md`)
- **S1 Typing**: in a real Codex TUI in Terminal, does `do script "x" in tab` submit, insert a
  newline, or arrive as a bracketed paste? Same for `\r` variants and the CGEvent fallback.
  Does it disturb a half-typed draft? (Use a harmless prompt; no limit needed.) Also capture
  the tab text after a real limit stop: plain message or an option picker?
- **S2 Tab ↔ thread mapping**: with two Codex tabs open, can we tell which thread belongs to
  which tab (cwd, tab history text, timing, app-server-control / ipc metadata, logs)?
- **S3 Terminal scripting**: tab `tty`, `busy`, `processes`, `history` access under hardened
  runtime + Automation consent; cost of reading `history` for long sessions.
- **S5 Delivery via app-server**: through `codex app-server proxy`, does `thread/loaded/list`
  show the Terminal TUI's thread, and does `turn/start` on it run visibly in that Terminal tab
  (no duplicate, TUI stays in sync)? Does it keep the thread's model/approval settings? What
  happens if the TUI is mid-turn? (Harmless prompt, no limit needed.)
- **S4 app-server lifetime**: one long-lived stdio child vs. per-poll spawn; memory/CPU; does it
  conflict with the shared daemon?

## 16. Decisions log
| # | Decision | By |
|---|---|---|
| D1 | Phase 1 = Codex CLI in Terminal.app only | owner |
| D2 | Name "Cybokron Limit Guard", repo `ercanatay/cybokron-limit-guard`, MIT, English | owner |
| D3 | Reset credits shown with expiry; per-credit manual **Use Reset** button in the popover | owner |
| D4 | Auto-spend only when weekly ≥ threshold and setting enabled; even if 5-hour not reached | owner |
| D5 | Never continue a finished task; loop guard with max tries | owner |
| D6 | Include: % in menu bar, daily usage chart, auto-update + downgrade, changelog, pause, next-action + cancel, keep-awake, notifications, activity log, editable continue text, launch at login | owner |
| D7 | Detection via `task_complete.error.codex_error_info == usage_limit_exceeded` | builder |
| D8 | Gate on `ordinaryUsageAllowed == true` only | builder |
| D9 | Max one automatic spend per weekly window; earliest-expiring credit first | builder |
| D10 | Expiring credits: reminder only, no auto-spend | builder |
| D11 | Confirmation alert before manual spend; countdown (10 s) before typing | builder |
| D12 | Multiple accounts deferred; app shows the active account/plan only | builder |
| D13 | v0.1.0 ships Developer ID signed + notarized (Dock Groups pipeline, `NOTARIZE_ENABLED=true` works since its v0.6.3) so Automation/Accessibility grants survive auto-updates | builder |
| D14 | Weekly-limit stop: if auto-spend is allowed → spend (§8) then continue (§7). Otherwise wait for `secondary.resetsAt`; such a stop stays eligible until `resetsAt + 1 h` instead of 24 h; keep-awake only when the wait is < 6 h. `workspace_owner_credits_depleted` is treated like any stop: only `ordinaryUsageAllowed == true` opens it, `reachedType` is diagnostic | builder |
| D15 | Auto-spend only while Codex is in use (turn in last 30 min or a session waiting on a stop) and not when the weekly window resets by itself within 12 h | owner |
| D16 | If a half-typed draft can't be ruled out: skip and notify, never type | owner |
| D17 | Live consume test: **not run** — owner stopped it on 2026-10-29 14:54 before it executed (both credits untouched). Consume stays verified only against the schema + FakeAppServer until the owner decides otherwise | owner |
| D18 | If Spike S2 can't separate tabs, v0.1.0 auto-continues only with exactly one Codex tab; several → notify + manual list | owner |
| D19 | Owner picks which Terminal tabs are guarded (opt-in, multi-select); default none; optional "guard new Codex tabs automatically" (off) | owner |
| D20 | Never type when a Codex selection screen/prompt is open in the tab | builder |
| D21 | Privacy: local only, no analytics, conversation text never stored by the app | builder |
| D22 | cybokron.com landing page EN+TR after the app ships (P1.5); other languages later (P6) | owner |
| D23 | First-run legal notice (independent tool, platform may restrict/suspend the account, as-is/MIT, own risk); must be accepted before any automatic action; re-shown on text change | owner |
| D24 | Delivery confirmation via `clientUserMessageId`; unconfirmed is never auto-resent | owner |
| D25 | Runaway brake: 3 auto-continued turns in a row each < 60 s → stop | owner |
| D26 | Diagnostics/Doctor incl. approval-policy warning | owner |
| D27 | Continue keeps the thread's model/effort/approval/sandbox — no overrides | owner |
| D28 | Burn-rate forecast for 5-hour and weekly windows | owner |
| D29 | "Limit is back" notification | owner |
| D30 | Spike S5: deliver via app-server `turn/start`; if it works it is the primary path, typing is fallback | owner |
