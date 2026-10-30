#!/usr/bin/env bash
# Builds "Cybokron Limit Guard.app" with SwiftPM, without Xcode (the Command Line Tools suffice).
#
#   scripts/build-app.sh [debug|release]      → build/<configuration>/Cybokron Limit Guard.app
#   UNIVERSAL=1 scripts/build-app.sh release  → arm64 + x86_64 binary
#   CODESIGN_IDENTITY=<SHA-1> scripts/build-app.sh release
#                                             → signed with that Developer ID Application identity
#                                               (hardened runtime, secure timestamp) instead of ad hoc
#   UPDATE_TEAM_IDENTIFIER=<team>             → with CODESIGN_IDENTITY: recorded in Info.plist as the
#                                               team the updater holds later versions to
#
# The Xcode project (project.yml / CybokronLimitGuard.xcodeproj) is the primary build; this script
# mirrors its settings. Keep the version numbers below in sync with project.yml.
set -euo pipefail

CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in
    debug | release) ;;
    *) echo "usage: $0 [debug|release]" >&2; exit 64 ;;
esac

APP_NAME="Cybokron Limit Guard"
BUNDLE_ID="com.cybokron.limitguard"
MARKETING_VERSION="0.1.0"
# CFBundleVersion: major * 10000 + minor * 100 + patch of MARKETING_VERSION (0.1.0 → 100; scripts/check-version.sh).
BUILD_NUMBER="100"
MINIMUM_MACOS="14.0"
PRODUCT="CybokronLimitGuard"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/swiftpm-env.sh

APP="$ROOT/build/$CONFIGURATION/$APP_NAME.app"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

BUILD_ARGS=(-c "$CONFIGURATION" ${SWIFTPM_FLAGS[@]+"${SWIFTPM_FLAGS[@]}"})
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build --product "$PRODUCT" "${BUILD_ARGS[@]}"
BINARY="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/$PRODUCT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

PLIST="$APP/Contents/Info.plist"
cp Resources/Info.plist "$PLIST"
plutil -replace CFBundleExecutable -string "$APP_NAME" "$PLIST"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$PLIST"
plutil -replace CFBundleName -string "$APP_NAME" "$PLIST"
plutil -replace CFBundleShortVersionString -string "$MARKETING_VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$PLIST"
plutil -replace LSMinimumSystemVersion -string "$MINIMUM_MACOS" "$PLIST"
# Developer ID builds name their team, so the updater holds later versions to it without reading
# the running app's signature.
if [[ -n "${CODESIGN_IDENTITY:-}" && -n "${UPDATE_TEAM_IDENTIFIER:-}" ]]; then
    if [[ ! "$UPDATE_TEAM_IDENTIFIER" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "error: UPDATE_TEAM_IDENTIFIER is not a team identifier" >&2
        exit 1
    fi
    plutil -replace CybokronUpdateTeamIdentifier -string "$UPDATE_TEAM_IDENTIFIER" "$PLIST"
fi
if grep -q '\$(' "$PLIST"; then
    echo "error: unresolved build setting left in Info.plist" >&2
    exit 1
fi
plutil -lint "$PLIST" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The asset catalog compiler needs Xcode; build the .icns from the catalog's PNGs instead.
ICONSET="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
cp Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"

# The string tables, as Xcode's resources phase copies them: every Resources/<language>.lproj
# folder (en.lproj holds the English text; translations add folders of their own).
for lproj in Resources/*.lproj; do
    [[ -d "$lproj" ]] || continue
    cp -R "$lproj" "$APP/Contents/Resources/"
done
if [[ ! -f "$APP/Contents/Resources/en.lproj/Localizable.strings" ]]; then
    echo "error: Resources/en.lproj/Localizable.strings is missing" >&2
    exit 1
fi
for table in "$APP"/Contents/Resources/*.lproj/*.strings; do
    plutil -lint "$table" >/dev/null
done

ENTITLEMENTS="$ROOT/Resources/CybokronLimitGuard.entitlements"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    # Release builds: Developer ID signature with the hardened runtime and a secure timestamp, as
    # notarization requires.
    codesign --force --deep --sign "$CODESIGN_IDENTITY" --options runtime --entitlements "$ENTITLEMENTS" --timestamp "$APP"
else
    codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" --timestamp=none "$APP"
fi
codesign --verify --strict "$APP"

echo "Built $APP"
lipo -archs "$APP/Contents/MacOS/$APP_NAME"
