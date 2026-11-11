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
  # Without an emulator, the nightly workflow's integration tests on this
  # commit count instead. Its integration-test job decides, not the run: the
  # randomized test can fail the run, and a night without commits skips the
  # integration tests in a run that passes.
  head=$(git rev-parse HEAD)
  passed= why= run_result=
  if ! command -v gh >/dev/null; then
    why="gh isn't installed, so the nightly runs can't be checked"
  # Completed runs on exactly this commit, newest first
  elif ! runs=$(gh run list --workflow nightly.yml --commit "$head" --limit 20 \
      --json databaseId,headSha,status,conclusion \
      --jq ".[] | select(.headSha == \"$head\" and .status == \"completed\") | \"\\(.databaseId) \\(.conclusion)\""); then
    why="gh couldn't list the nightly runs (see above)"
  elif [ -z "$runs" ]; then
    why="no completed nightly run on $head (not pushed, or still running?)"
  else
    # The newest one decides: a failure after a pass on the same commit is
    # a flaky test to look at, not something an older pass makes up for
    newest=${runs%%$'\n'*}
    id=${newest%% *} run_result=${newest#* }
    result=$(gh run view "$id" --json jobs --jq \
      '[.jobs[] | select(.name == "integration-test")
        | if .status == "completed" then .conclusion else .status end][0]
        // "missing"') || result="unknown (gh failed)"
    if [ "$result" = success ]; then
      passed=$id
    else
      why="newest completed nightly run on $head: $id, integration-test $result"
    fi
  fi
  if [ -n "$passed" ]; then
    echo "No Android emulator running; nightly run $passed passed the integration tests on $head."
    # Another job of it (the randomized test) doesn't stop a release, but
    # shouldn't go unnoticed either
    [ "$run_result" = success ] ||
      echo "The run itself is $run_result: see its other jobs (gh run view $passed)."
  else
    echo "No Android emulator running, so the integration tests can't run here, and no passed nightly run could be confirmed for this commit: $why."
    echo "Start an emulator (see docs/ANDROID.md), or run them in CI (gh workflow run nightly.yml) and run this again once it passed."
    answer=
    read -r -p "Release without them? [y/N] " answer || true
    [ "$answer" = y ] || { echo "Not released." >&2; exit 1; }
  fi
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
