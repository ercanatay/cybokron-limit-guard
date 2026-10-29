# Contributing to Cybokron Limit Guard

Thanks for your interest! Bug reports, ideas and pull requests are all welcome.

- **Questions and ideas:** [Discussions](https://github.com/ercanatay/cybokron-limit-guard/discussions)
- **Bugs and concrete feature requests:** [Issues](https://github.com/ercanatay/cybokron-limit-guard/issues/new/choose)
- **Security problems:** see [SECURITY.md](SECURITY.md) — please report them privately.

## Development setup

Requirements: macOS 14 or later, and Xcode 16+ **or** just the Command Line Tools.

```sh
git clone https://github.com/ercanatay/cybokron-limit-guard.git
cd cybokron-limit-guard

scripts/test.sh                 # unit tests (SwiftPM)
scripts/build-app.sh debug      # build/debug/Cybokron Limit Guard.app
```

See the [README](README.md#building) for details.

## Project structure

- `Sources/LimitGuardCore` — logic and persistence; no UI. Put logic here so it can be unit-tested.
- `Sources/CybokronLimitGuard` — AppKit lifecycle, menu bar, popover and SwiftUI windows.
- `Tests/LimitGuardCoreTests` — swift-testing tests for the core.

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
After adding or removing source files, run `xcodegen generate` and commit the updated project.
No third-party packages: system frameworks only.

## Ground rules

- **Never call the real reset-credit endpoint** (`account/rateLimitResetCredit/consume`) from tests
  or while developing. Spend paths are tested against the fake app-server.
- Never read `~/.codex/auth.json` and never write into `~/.codex`.
- Every user-visible string needs an English and a Turkish key in `Resources/en.lproj` and
  `Resources/tr.lproj`; `LocalizationTests` check that the keys and placeholders match.
- The design is in [docs/design/limit-guard-spec.md](docs/design/limit-guard-spec.md); please read
  it before a substantial change.

## Pull requests

1. Create a branch from `main`.
2. Keep changes focused; add or update tests in `LimitGuardCoreTests` for core changes.
3. Make sure `scripts/test.sh` passes — CI runs the same tests.
4. Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`,
   `build:`, `ci:` …).
5. Open the PR and describe what you changed and how you tested it.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
