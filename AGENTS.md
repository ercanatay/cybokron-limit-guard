# AGENTS.md

Instructions for AI coding agents (Claude, Codex, OpenCode, Copilot, …) working in this repository.

## Project

Cybokron Limit Guard is a macOS 14+ menu bar app (Swift, AppKit, no third-party dependencies) that
watches Codex CLI usage limits and continues interrupted Codex sessions once a limit resets,
delivering the message through the Codex app-server (no keystrokes, no Automation permission). Read [docs/design/limit-guard-spec.md](docs/design/limit-guard-spec.md) before implementing
a substantial change.

- `Sources/LimitGuardCore` — logic, persistence, localisation lookup. No UI; keep logic here so it is testable.
- `Sources/CybokronLimitGuard` — app lifecycle, menu bar, windows, `L10n`.
- `Tests/LimitGuardCoreTests` — swift-testing unit tests.

## Commands

```sh
scripts/test.sh                 # run unit tests (SwiftPM); extra args go to `swift test`
scripts/build-app.sh debug      # build/debug/Cybokron Limit Guard.app
```

Run `scripts/test.sh` before committing. After adding or removing source files or changing
`project.yml`, run `xcodegen generate` and commit the regenerated `CybokronLimitGuard.xcodeproj`.
Keep version numbers in `scripts/build-app.sh` and `project.yml` in sync; `scripts/check-version.sh`
(run by CI) checks them against `project.pbxproj` and, for tags, the tag. The build number
(`CURRENT_PROJECT_VERSION`, the app's `CFBundleVersion`) is major × 10000 + minor × 100 + patch
(0.1.0 → 100).

## Conventions

- Commits, PRs and repository documentation are in English; [Conventional Commits](https://www.conventionalcommits.org/).
- Never force push to or delete `main`.
- Every user-visible string needs `en` + `tr` keys: it goes through `L10n` with its key in
  `Resources/en.lproj/Localizable.strings` and `Resources/tr.lproj/Localizable.strings`;
  `LocalizationTests` check keys and placeholders. `tr` values are produced with the Haiku script
  (`~/.claude/scripts/haiku-translate.sh`) and reviewed before merging.
- No third-party packages (SwiftPM dependencies); system frameworks only.
- No UI scripting (System Events, `osascript` clicks or keystrokes, `cliclick`, synthetic input).
  Verify UI by building and, if needed, launching the app with `CYBOKRON_LG_DATA_DIR=<temp dir>`
  (DEBUG); never run it against the real data directory.
- No "LG" letters in any icon or asset (confusable with another brand).
- Never read `~/.codex/auth.json`; open `~/.codex/state_5.sqlite` read-only; never write into `~/.codex`.
- Never call `account/rateLimitResetCredit/consume` against a real account — not from tests, not during
  development; spend paths are tested with the fake app-server.
- The signing team's organisation name must not appear in the repo, commits or release text.
