#!/usr/bin/env bash
# Runs the LimitGuardCore unit tests with SwiftPM (works with the Command Line Tools alone).
# Extra arguments are passed to `swift test`, e.g. scripts/test.sh --filter GroupStore
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/swiftpm-env.sh

swift test ${SWIFTPM_FLAGS[@]+"${SWIFTPM_FLAGS[@]}"} "$@"
