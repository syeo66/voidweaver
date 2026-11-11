#!/usr/bin/env bash
# Bumps the version in pubspec.yaml, commits, tags and pushes; the tag makes
# CI publish the release (see docs/RELEASING.md).
#
#   tool/release.sh patch|minor|major   # 1.1.0 -> 1.1.1 | 1.2.0 | 2.0.0
#   tool/release.sh 1.3.0-beta.1        # an explicit version
#   tool/release.sh patch --dry-run     # only print the new version
#
# Asks before pushing. The build number (+N) in pubspec.yaml stays: the
# commit count wins, see docs/DEVELOPMENT.md.

set -euo pipefail

cd "$(dirname "$0")/.."
arg="${1:?usage: tool/release.sh patch|minor|major|X.Y.Z [--dry-run]}"
dry="${2:-}"

current=$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' pubspec.yaml)
IFS=. read -r major minor patch <<<"${current%%-*}"
case "$arg" in
  patch) new="$major.$minor.$((patch + 1))" ;;
  minor) new="$major.$((minor + 1)).0" ;;
  major) new="$((major + 1)).0.0" ;;
  *) new="$arg" ;;
esac
[[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "Not a version: $new" >&2; exit 2; }
echo "$current -> $new"
[ "$dry" = "--dry-run" ] && exit 0

[ "$(git branch --show-current)" = main ] || { echo "Not on main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Working tree isn't clean" >&2; exit 1; }
git rev-parse "v$new" >/dev/null 2>&1 && { echo "Tag v$new exists" >&2; exit 1; }

# The integration tests, which CI doesn't run before a release (only nightly,
# see docs/RELEASING.md). Only on an emulator: they reinstall the app and
# clear its data, which on a phone would remove its login and cache.
command -v jq >/dev/null || { echo "jq is needed to find an emulator" >&2; exit 1; }
devices=$(flutter devices --machine) ||
  { echo "flutter devices failed, can't look for an emulator" >&2; exit 1; }
# The first running Android emulator, in flutter's order
emulator=$(jq -r '[.[] | select(.emulator and (.targetPlatform | startswith("android")))][0].id // empty' <<<"$devices") ||
  { echo "Can't read the output of flutter devices" >&2; exit 1; }
if [ -n "$emulator" ]; then
  echo "Running the integration tests on $emulator..."
  flutter test integration_test -d "$emulator" ||
    { echo "Integration tests failed, not releasing" >&2; exit 1; }
else
  answer=
  read -r -p "No Android emulator running, so the integration tests can't run. Release without them? [y/N] " answer || true
  [ "$answer" = y ] || { echo "Not released. Start one (see docs/ANDROID.md) and run this again." >&2; exit 1; }
fi
# The commit below takes every changed file; flutter's implicit pub get can
# rewrite a pubspec.lock
[ -z "$(git status --porcelain)" ] ||
  { echo "The integration tests changed files, not releasing:" >&2; git status --short >&2; exit 1; }

sed -i.bak "s/^version: *[^+ ]*/version: $new/" pubspec.yaml && rm pubspec.yaml.bak
git commit -q -am "release v$new"
git tag "v$new"
echo "Committed and tagged v$new."

read -r -p "Push main and v$new to origin? [y/N] " answer
if [ "$answer" = y ]; then
  git push origin main "v$new"
else
  echo "Not pushed. To undo: git tag -d v$new && git reset --hard HEAD~1"
fi
