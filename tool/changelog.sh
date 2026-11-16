#!/usr/bin/env bash
# The CHANGELOG.md sections, for tool/release.sh and the release job of
# .github/workflows/flutter.yml (see docs/RELEASING.md).
#
#   tool/changelog.sh notes Unreleased|X.Y.Z   # the text of a section, without its heading; empty if none
#   tool/changelog.sh release X.Y.Z            # moves the Unreleased text under a new "## X.Y.Z - date" heading
#
# Plain awk, so it runs the same on macOS and on the CI runner.

set -euo pipefail

cd "$(dirname "$0")/.."
file="${CHANGELOG_FILE:-CHANGELOG.md}"
mode="${1:?usage: tool/changelog.sh notes|release VERSION}"
version="${2:?usage: tool/changelog.sh notes|release VERSION}"

case "$mode" in
  notes)
    # Between the section's heading and the next one, without the blank
    # lines around it
    awk -v v="$version" '
      /^## / {
        if (found) exit
        split($0, heading, " ")
        if (heading[2] == v) found = 1
        next
      }
      found {
        lines[++n] = $0
        if ($0 !~ /^[[:space:]]*$/) { if (!first) first = n; last = n }
      }
      END { for (i = first; first && i <= last; i++) print lines[i] }
    ' "$file"
    ;;
  release)
    grep -q '^## Unreleased[[:space:]]*$' "$file" ||
      { echo "No '## Unreleased' heading in $file" >&2; exit 1; }
    grep -q "^## $version[[:space:]]" "$file" &&
      { echo "$file has a section for $version already" >&2; exit 1; }
    tmp=$(mktemp)
    awk -v v="$version" -v d="$(date +%F)" '
      /^## Unreleased[[:space:]]*$/ && !done { print; print ""; print "## " v " - " d; done = 1; next }
      { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
    ;;
  *)
    echo "usage: tool/changelog.sh notes|release VERSION" >&2
    exit 2
    ;;
esac
