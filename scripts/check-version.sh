#!/usr/bin/env bash
# Checks that the app's version (MARKETING_VERSION) is the same everywhere it's written:
# scripts/build-app.sh, project.yml and the app target's two build configurations in
# CybokronLimitGuard.xcodeproj/project.pbxproj. When GITHUB_REF_NAME names a version tag (v*, and
# GITHUB_REF_TYPE is "tag" or unset), the tag must be v<version> too. Exits 1 on any mismatch.
#
# The build number (CFBundleVersion: BUILD_NUMBER in build-app.sh, CURRENT_PROJECT_VERSION in
# project.yml and project.pbxproj) must be derived from the version as
# major * 10000 + minor * 100 + patch (0.6.4 → 604, 1.2.0 → 10200), so it grows with every release
# and LaunchServices picks the newest copy of the app; minor and patch must stay below 100.
#
#   scripts/check-version.sh                         → checks this checkout
#   GITHUB_REF_NAME=v0.6.1 scripts/check-version.sh  → also checks the tag
#   scripts/check-version.sh <root>                  → checks the checkout at <root>
#   APP_PATH=<app> scripts/check-version.sh          → also checks a built app's Info.plist
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
BUILD_SCRIPT="$ROOT/scripts/build-app.sh"
PROJECT_YML="$ROOT/project.yml"
PBXPROJ="$ROOT/CybokronLimitGuard.xcodeproj/project.pbxproj"

failures=0
fail() {
  echo "error: $*" >&2
  failures=$((failures + 1))
}

for file in "$BUILD_SCRIPT" "$PROJECT_YML" "$PBXPROJ"; do
  if [[ ! -f "$file" ]]; then
    echo "error: $file not found" >&2
    exit 1
  fi
done

# One value per line; nothing when the setting is missing.
build_versions="$(sed -nE 's/^MARKETING_VERSION="([^"]*)".*/\1/p' "$BUILD_SCRIPT")"
yml_versions="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]*)"?.*/\1/p' "$PROJECT_YML")"
pbx_versions="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = "?([^";]*)"?;.*/\1/p' "$PBXPROJ")"
build_numbers="$(sed -nE 's/^BUILD_NUMBER="([^"]*)".*/\1/p' "$BUILD_SCRIPT")"
yml_builds="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([^"[:space:]]*)"?.*/\1/p' "$PROJECT_YML")"
pbx_builds="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = "?([^";]*)"?;.*/\1/p' "$PBXPROJ")"

count() { [[ -z "$1" ]] && echo 0 || grep -c '' <<< "$1"; }

if [[ "$(count "$build_versions")" -ne 1 || -z "$build_versions" ]]; then
  echo "error: scripts/build-app.sh must set MARKETING_VERSION=\"<version>\" exactly once" >&2
  exit 1
fi
VERSION="$build_versions"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  fail "scripts/build-app.sh: MARKETING_VERSION \"$VERSION\" isn't a version number"
fi

if [[ "$(count "$yml_versions")" -ne 1 ]]; then
  fail "project.yml: expected one MARKETING_VERSION, found $(count "$yml_versions")"
elif [[ "$yml_versions" != "$VERSION" ]]; then
  fail "project.yml: MARKETING_VERSION is $yml_versions, scripts/build-app.sh has $VERSION"
fi

if [[ "$(count "$pbx_versions")" -ne 2 ]]; then
  fail "project.pbxproj: expected MARKETING_VERSION in 2 build configurations, found $(count "$pbx_versions") (run xcodegen generate)"
fi
while IFS= read -r version; do
  [[ -z "$version" || "$version" == "$VERSION" ]] && continue
  fail "project.pbxproj: MARKETING_VERSION is $version, scripts/build-app.sh has $VERSION (run xcodegen generate)"
done <<< "$pbx_versions"

# The build number: major * 10000 + minor * 100 + patch of the version.
BUILD=""
if [[ "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
  major=$((10#${BASH_REMATCH[1]}))
  minor=$((10#${BASH_REMATCH[2]}))
  patch=$((10#${BASH_REMATCH[3]}))
  if (( minor > 99 || patch > 99 )); then
    fail "version $VERSION: minor and patch must be below 100 for the build number (major * 10000 + minor * 100 + patch)"
  else
    BUILD=$((major * 10000 + minor * 100 + patch))
  fi
fi

if [[ -n "$BUILD" ]]; then
  if [[ "$(count "$build_numbers")" -ne 1 ]]; then
    fail "scripts/build-app.sh: expected one BUILD_NUMBER, found $(count "$build_numbers")"
  elif [[ "$build_numbers" != "$BUILD" ]]; then
    fail "scripts/build-app.sh: BUILD_NUMBER is $build_numbers, version $VERSION needs $BUILD"
  fi
  if [[ "$(count "$yml_builds")" -ne 1 ]]; then
    fail "project.yml: expected one CURRENT_PROJECT_VERSION, found $(count "$yml_builds")"
  elif [[ "$yml_builds" != "$BUILD" ]]; then
    fail "project.yml: CURRENT_PROJECT_VERSION is $yml_builds, version $VERSION needs $BUILD"
  fi
  if [[ "$(count "$pbx_builds")" -ne 2 ]]; then
    fail "project.pbxproj: expected CURRENT_PROJECT_VERSION in 2 build configurations, found $(count "$pbx_builds") (run xcodegen generate)"
  fi
  while IFS= read -r build; do
    [[ -z "$build" || "$build" == "$BUILD" ]] && continue
    fail "project.pbxproj: CURRENT_PROJECT_VERSION is $build, version $VERSION needs $BUILD (run xcodegen generate)"
  done <<< "$pbx_builds"
fi

# A built app (APP_PATH) must carry the same version and build number.
if [[ -n "${APP_PATH:-}" ]]; then
  INFO_PLIST="$APP_PATH/Contents/Info.plist"
  if [[ ! -f "$INFO_PLIST" ]]; then
    fail "$INFO_PLIST not found"
  else
    app_version="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST" 2>/dev/null || true)"
    app_build="$(plutil -extract CFBundleVersion raw "$INFO_PLIST" 2>/dev/null || true)"
    echo "CFBundleShortVersionString: $app_version"
    echo "CFBundleVersion: $app_build"
    [[ "$app_version" == "$VERSION" ]] || fail "$APP_PATH: CFBundleShortVersionString is $app_version, expected $VERSION"
    [[ "$app_build" == "$BUILD" ]] || fail "$APP_PATH: CFBundleVersion is $app_build, expected $BUILD"
  fi
fi

REF="${GITHUB_REF_NAME:-}"
if [[ -n "$REF" && "${GITHUB_REF_TYPE:-tag}" == "tag" && "$REF" == v* ]]; then
  if [[ "$REF" != "v$VERSION" ]]; then
    fail "tag $REF doesn't match version $VERSION (expected v$VERSION)"
  else
    echo "Tag $REF matches version $VERSION."
  fi
fi

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
echo "Version $VERSION (build $BUILD): scripts/build-app.sh, project.yml and project.pbxproj (2 build configurations) agree."
