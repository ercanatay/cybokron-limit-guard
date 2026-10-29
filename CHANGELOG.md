# Changelog

All notable changes to Cybokron Limit Guard are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - Unreleased

First release (Phase 1: Codex CLI).

### Added

- Menu bar item with a gauge icon and an optional percentage of the more critical limit window.
- Popover with the 5-hour and weekly limits, reset times, a next-action row with Cancel, and the
  reset credits panel (expiry dates, **Use Reset** with confirmation).
- Auto-continue: after a usage-limit stop, wait until usage is allowed again and send a "continue"
  message to that conversation through the Codex app-server, in the conversation's language, with a
  cancellable countdown and delivery confirmation. Subagent threads are not continued directly.
- Loop guard (max continues, minimum gap) and a runaway brake.
- Optional auto-use of one reset credit when the weekly limit is almost used up (off by default;
  at most one per account every 7 days; ledger with idempotency key written before the call).
- Burn-rate forecast, usage chart (daily tokens and limit history), "Limit is back" and expiry
  notifications, keep-awake while waiting, Activity log, Pause/Resume, launch at login.
- First-run legal notice, Diagnostics, About, Settings, automatic updates with Other Versions…
  and a changelog window.
- English and Turkish interface.
- Project documentation: README, SECURITY, CONTRIBUTING, AGENTS.
- Project scaffold: SwiftPM and XcodeGen builds, string tables and CI.
