#!/usr/bin/env bash
# Takes the README screenshots (docs/screenshots/<scene>-<light|dark>.png) from a debug build in
# screenshot mode (`-LGScreenshotScene`, Sources/CybokronLimitGuard/System/ScreenshotMode.swift):
# made-up data in a temporary folder, no codex process, English text.
#
#   scripts/screenshots.sh                    → every scene, light and dark
#   scripts/screenshots.sh popover about      → only these scenes
#
# The app runs under its own bundle id, so it neither hands over to an installed copy nor writes
# that copy's preferences. Needs Screen Recording permission for the terminal that runs it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ALL_SCENES=(popover settings-general settings-continue settings-resets activity chart about notice)
SCENES=("$@")
[[ ${#SCENES[@]} -gt 0 ]] || SCENES=("${ALL_SCENES[@]}")
APPEARANCES=(light dark)
OUT="$ROOT/docs/screenshots"
MAX_WIDTH=1200
SCREENSHOT_BUNDLE_ID="com.cybokron.limitguard.screenshots"
SRGB_PROFILE="/System/Library/ColorSync/Profiles/sRGB Profile.icc"

scripts/build-app.sh debug >/dev/null

WORK_DIR="$(mktemp -d)"
APP_PID=""
cleanup() {
    if [[ -n "$APP_PID" ]]; then kill "$APP_PID" 2>/dev/null || true; fi
    rm -rf "$WORK_DIR"
    defaults delete "$SCREENSHOT_BUNDLE_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

APP="$WORK_DIR/Cybokron Limit Guard.app"
cp -R "$ROOT/build/debug/Cybokron Limit Guard.app" "$APP"
plutil -replace CFBundleIdentifier -string "$SCREENSHOT_BUNDLE_ID" "$APP/Contents/Info.plist"
codesign --force --sign - --options runtime --entitlements "$ROOT/Resources/CybokronLimitGuard.entitlements" \
    --timestamp=none "$APP" 2>/dev/null
BINARY="$APP/Contents/MacOS/Cybokron Limit Guard"

mkdir -p "$OUT"
for scene in "${SCENES[@]}"; do
    for appearance in "${APPEARANCES[@]}"; do
        data_dir="$WORK_DIR/data-$scene-$appearance"
        log="$WORK_DIR/$scene-$appearance.log"
        # UTC: the credit rows name the time zone, which should not be the one of the Mac taking them.
        TZ=UTC CYBOKRON_LG_DATA_DIR="$data_dir" "$BINARY" \
            -AppleLanguages "(en)" -AppleLocale en_US \
            -LGScreenshotScene "$scene" -LGAppearance "$appearance" >"$log" 2>"$log.err" &
        APP_PID=$!

        window_id=""
        for _ in $(seq 1 100); do
            window_id="$(sed -n 's/^LG_WINDOW_ID=\([0-9][0-9]*\)$/\1/p' "$log" | head -n 1)"
            [[ -n "$window_id" ]] && break
            kill -0 "$APP_PID" 2>/dev/null || break
            sleep 0.2
        done
        if [[ -z "$window_id" ]]; then
            echo "error: $scene ($appearance): no window id" >&2
            tail -n 20 "$log.err" >&2 || true
            exit 1
        fi
        sleep 0.5

        png="$OUT/$scene-$appearance.png"
        screencapture -o -x -l "$window_id" "$png"
        # The capture carries the display's colour profile, which names the monitor: use sRGB instead.
        sips --matchTo "$SRGB_PROFILE" "$png" >/dev/null
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
        APP_PID=""

        width="$(sips -g pixelWidth "$png" | awk '/pixelWidth/ { print $2 }')"
        if [[ "$width" -gt "$MAX_WIDTH" ]]; then
            sips --resampleWidth "$MAX_WIDTH" "$png" >/dev/null
        fi
        echo "$png"
    done
done
