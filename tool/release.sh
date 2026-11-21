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

# What users read on the release page: CHANGELOG.md's Unreleased section, which
# goes on top of the generated list of commits. Asked before the checks below,
# which take minutes.
notes=$(tool/changelog.sh notes Unreleased)
if [ -z "$notes" ]; then
  echo "CHANGELOG.md has nothing under '## Unreleased'; the release page would only list commits." >&2
  answer=
  read -r -p "Release without notes? [y/N] " answer || true
  [ "$answer" = y ] || { echo "Not released: write the notes, commit them, and run this again." >&2; exit 1; }
fi

# The generated mocks must match their @GenerateMocks annotations, as CI's
# test job checks. The push of the release commit skips CI, so without this
# only the tag's run would notice, after the tag is out. The tree is clean
# here, so any change is build_runner's.
echo "Checking the generated mocks..."
mocks_log=$(dart run build_runner build 2>&1) ||
  { echo "$mocks_log" >&2; echo "build_runner failed, not releasing" >&2; exit 1; }
if [ -n "$(git status --porcelain)" ]; then
  git status --short >&2
  echo "Regenerating the mocks changed these files (out-of-date mocks, or pub get rewrote pubspec.lock): commit them, then release again." >&2
  exit 1
fi

# The integration tests, which CI doesn't run before a release (only nightly,
# see docs/RELEASING.md). Only on an emulator: they reinstall the app and
# clear its data, which on a phone would remove its login and cache.
command -v jq >/dev/null || { echo "jq is needed to find an emulator" >&2; exit 1; }
devices=$(flutter devices --machine) ||
  { echo "flutter devices failed, can't look for an emulator" >&2; exit 1; }
# The first running Android emulator, in flutter's order
emulator=$(jq -r '[.[] | select(.emulator and (.targetPlatform | startswith("android")))][0].id // empty' <<<"$devices") ||
  { echo "Can't read the output of flutter devices" >&2; exit 1; }
# Without an emulator, the nightly workflow's jobs on this commit count
# instead. Sets `passed` to the id of the newest completed nightly run on
# HEAD if its job $1 passed, otherwise `why` to the reason it can't count;
# `run_result` is that run's conclusion, `job_result` the job's (empty
# without a run, `missing` if the run has no such job). The job decides, not
# the run: the randomized test can fail the run, and a night without commits
# skips the emulator jobs in a run that passes.
head=$(git rev-parse HEAD)
nightly_runs= nightly_runs_error=
nightly_job() {
  local job="$1" newest id result
  passed= why= run_result= job_result=
  if ! command -v gh >/dev/null; then
    why="gh isn't installed, so the nightly runs can't be checked"
    return
  fi
  # Completed runs on exactly this commit, newest first; listed once
  if [ -z "$nightly_runs" ] && [ -z "$nightly_runs_error" ]; then
    nightly_runs=$(gh run list --workflow nightly.yml --commit "$head" --limit 20 \
        --json databaseId,headSha,status,conclusion \
        --jq ".[] | select(.headSha == \"$head\" and .status == \"completed\") | \"\\(.databaseId) \\(.conclusion)\"") ||
      nightly_runs_error="gh couldn't list the nightly runs (see above)"
  fi
  if [ -n "$nightly_runs_error" ]; then
    why=$nightly_runs_error
  elif [ -z "$nightly_runs" ]; then
    why="no completed nightly run on $head (not pushed, or still running?)"
  else
    # The newest one decides: a failure after a pass on the same commit is
    # a flaky test to look at, not something an older pass makes up for
    newest=${nightly_runs%%$'\n'*}
    id=${newest%% *} run_result=${newest#* }
    result=$(gh run view "$id" --json jobs --jq \
      "[.jobs[] | select(.name == \"$job\")
        | if .status == \"completed\" then .conclusion else .status end][0]
        // \"missing\"") || result="unknown (gh failed)"
    job_result=$result
    if [ "$result" = success ]; then
      passed=$id
    else
      why="newest completed nightly run on $head: $id, $job $result"
    fi
  fi
}

if [ -n "$emulator" ]; then
  echo "Running the integration tests on $emulator..."
  flutter test integration_test -d "$emulator" ||
    { echo "Integration tests failed, not releasing" >&2; exit 1; }
else
  nightly_job integration-test
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

# The release-build checks (tool/emulator_check.sh: the R8-shrunk APK's media
# session, notification, media keys, resumption, see docs/ANDROID.md). The
# integration tests use a debug build, so they don't stand in for them.
# Against the fake server, so no login is needed; like the integration tests,
# they clear the app's data, so only on the emulator found above
# (ANDROID_SERIAL, as the script's adb calls name no device).
if [ -n "$emulator" ]; then
  echo "Running the release-build checks on $emulator (builds a release APK, takes a few minutes)..."
  status=0
  ANDROID_SERIAL="$emulator" tool/emulator_check.sh --fake-server --build || status=$?
  case "$status" in
    0) ;;
    # The script couldn't run here (an emulator without arm64 or x86_64, the
    # fake server didn't start), which says nothing about the build
    2)
      echo "The release-build checks couldn't run on $emulator (see above)." >&2
      answer=
      read -r -p "Release without them? [y/N] " answer || true
      [ "$answer" = y ] || { echo "Not released." >&2; exit 1; }
      ;;
    # The build, the install or a check failed; a failed check leaves its
    # diagnostics in build/emulator-check/diagnostics/
    *) echo "Release-build checks failed (see above), not releasing" >&2; exit 1 ;;
  esac
else
  nightly_job release-build-check
  if [ -n "$passed" ]; then
    echo "No Android emulator running; nightly run $passed passed the release-build checks on $head."
  elif case "$job_result" in ""|skipped|missing|"unknown (gh failed)") false ;; *) true ;; esac; then
    # They ran on exactly this commit and didn't pass (failed, cancelled,
    # timed out): never skipped, whatever changed since the last tag
    echo "No Android emulator running, and the release-build checks didn't pass in the nightly workflow on this commit: $why."
    echo "Look at that run (its emulator-check-diagnostics artifact), start an emulator (see docs/ANDROID.md) or run them in CI again (gh workflow run nightly.yml)."
    answer=
    read -r -p "Release without them? [y/N] " answer || true
    [ "$answer" = y ] || { echo "Not released." >&2; exit 1; }
  else
    # Without a passed nightly run, they're asked for when something they
    # cover changed since the last release: the native layer, the plugins
    # (pubspec.lock), the Flutter version or the release build itself
    last_tag=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null) || last_tag=
    nightly_why=$why
    stop_unless_yes() {
      echo "No passed nightly run could be confirmed for this commit either: $nightly_why."
      echo "Start an emulator (see docs/ANDROID.md), or run them in CI (gh workflow run nightly.yml) and run this again once it passed."
      answer=
      read -r -p "Release without them? [y/N] " answer || true
      [ "$answer" = y ] || { echo "Not released." >&2; exit 1; }
    }
    if [ -z "$last_tag" ]; then
      echo "No Android emulator running, so the release-build checks (tool/emulator_check.sh) can't run, and with no earlier release tag there's no telling what they'd cover."
      stop_unless_yes
    else
      changed=$(git diff --name-only "$last_tag" HEAD -- \
        android packages/voidweaver_player pubspec.lock .flutter-version tool/build_release_apk.sh)
      if [ -n "$changed" ]; then
        echo "No Android emulator running, so the release-build checks (tool/emulator_check.sh) can't run here. Changed since $last_tag:"
        head -10 <<<"$changed" | sed 's/^/  /'
        count=$(wc -l <<<"$changed")
        [ "$count" -le 10 ] || echo "  ... and $((count - 10)) more"
        stop_unless_yes
      else
        echo "No Android emulator running; skipping the release-build checks (no native, plugin or toolchain change since $last_tag; nightly: $nightly_why)."
      fi
    fi
  fi
fi

# The commit below takes every changed file; flutter's implicit pub get can
# rewrite a pubspec.lock
[ -z "$(git status --porcelain)" ] ||
  { echo "The checks changed files, not releasing:" >&2; git status --short >&2; exit 1; }

sed -i.bak "s/^version: *[^+ ]*/version: $new/" pubspec.yaml && rm pubspec.yaml.bak
# The notes move under the new version, in the release commit
[ -z "$notes" ] || tool/changelog.sh release "$new"
git commit -q -am "release v$new"
git tag "v$new"
echo "Committed and tagged v$new."

read -r -p "Push main and v$new to origin? [y/N] " answer
if [ "$answer" = y ]; then
  git push origin main "v$new"
else
  echo "Not pushed. To undo: git tag -d v$new && git reset --hard HEAD~1"
fi
