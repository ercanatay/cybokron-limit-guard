#!/usr/bin/env bash
# Extracts the release notes for one version from CHANGELOG.md.
#
#   scripts/release-notes.sh v0.6.1            → notes on stdout
#   scripts/release-notes.sh 0.6.1 notes.md     → notes written to notes.md
#
# The notes are the "## [<version>] - <date>" section up to the next "## [" heading (heading
# included, link reference definitions excluded), followed by "**Full Changelog**: <url>" taken
# from the "[<version>]: <url>" reference at the bottom of CHANGELOG.md. Fails if the section is
# missing or empty. Lines inside fenced code blocks (``` or ~~~) are kept as they are: a heading or a
# link reference there doesn't end the section, start one, or give the compare link.
#
# CHANGELOG_PATH reads another file instead of the repository's CHANGELOG.md (for the tests).
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <version|vVERSION> [output-file]" >&2
  exit 64
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="${CHANGELOG_PATH:-$ROOT/CHANGELOG.md}"
VERSION="${1#v}"
OUTPUT="${2:-}"

NOTES="$(python3 - "$CHANGELOG" "$VERSION" <<'PY'
import re
import sys

path, version = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    lines = f.read().splitlines()

heading = re.compile(r"^## \[" + re.escape(version) + r"\](\s|$)")
link_ref = re.compile(r"^\[[^\]]+\]:\s*\S")
# \x60 is a backtick: a literal one, or an unpaired quote, here breaks bash 3.2 command substitution.
fence_line = re.compile(r"^\s*(\x60{3,}|~{3,})(.*)$")

# outside[i]: line i is Markdown, not part of a fenced code block (fence lines included).
outside = []
fence = None
for line in lines:
    match = fence_line.match(line)
    if fence is None:
        if match:
            fence = match.group(1)
        outside.append(fence is None)
    else:
        outside.append(False)
        if match and match.group(1)[0] == fence[0] and len(match.group(1)) >= len(fence) and not match.group(2).strip():
            fence = None

start = next((i for i, line in enumerate(lines) if outside[i] and heading.match(line)), None)
if start is None:
    sys.exit(f"error: no '## [{version}]' section in {path}")

end = next((i for i in range(start + 1, len(lines)) if outside[i] and lines[i].startswith("## [")), len(lines))
section = [line for i, line in enumerate(lines[start:end], start) if not (outside[i] and link_ref.match(line))]
while section and not section[-1].strip():
    section.pop()
if len(section) < 2 or not any(line.strip() for line in section[1:]):
    sys.exit(f"error: the '## [{version}]' section in {path} is empty")

ref = re.compile(r"^\[" + re.escape(version) + r"\]:\s*(\S+)")
url = next((m.group(1) for i, m in enumerate(map(ref.match, lines)) if m and outside[i]), None)
if url:
    section += ["", f"**Full Changelog**: {url}"]
else:
    print(f"warning: no '[{version}]: <url>' reference in {path}; omitting the compare link",
          file=sys.stderr)

print("\n".join(section))
PY
)"

if [[ -n "$OUTPUT" ]]; then
  printf '%s\n' "$NOTES" > "$OUTPUT"
else
  printf '%s\n' "$NOTES"
fi
