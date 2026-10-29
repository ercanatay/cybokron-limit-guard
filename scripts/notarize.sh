#!/usr/bin/env bash
# Sends a file to Apple's notary service and waits for the verdict.
#
#   ASC_KEY_PATH=<AuthKey_XXXX.p8> ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id> \
#       scripts/notarize.sh <file.zip|file.dmg>
#
# Uses an App Store Connect API key. Prints the submission result; unless it is Accepted, prints
# the notary log and fails. Stapling is left to the caller: for a zip, staple the app that went into
# it; for a DMG, staple the DMG.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <file.zip|file.dmg>" >&2
    exit 64
fi
FILE="$1"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH to the App Store Connect API key (.p8)}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
AUTH=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")

RESULT="$(mktemp)"
trap 'rm -f "$RESULT"' EXIT
# Notarization usually takes minutes; wait up to 90. A submission stuck "In Progress" for hours
# can be sent again.
xcrun notarytool submit "$FILE" "${AUTH[@]}" --wait --timeout 90m --output-format json > "$RESULT" || true
cat "$RESULT"
echo
STATUS="$(plutil -extract status raw "$RESULT" 2>/dev/null || echo unknown)"
SUBMISSION_ID="$(plutil -extract id raw "$RESULT" 2>/dev/null || true)"
if [[ "$STATUS" != "Accepted" ]]; then
    if [[ -n "$SUBMISSION_ID" ]]; then
        xcrun notarytool log "$SUBMISSION_ID" "${AUTH[@]}" || true
    fi
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "::error::Notarization of $(basename "$FILE"): $STATUS"
    else
        echo "error: notarization of $FILE: $STATUS" >&2
    fi
    exit 1
fi
echo "Notarized $FILE (submission $SUBMISSION_ID)"
