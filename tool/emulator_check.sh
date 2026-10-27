#!/usr/bin/env bash
# Checks the system integration of a release build in a running emulator:
# media session, notification, media keys (the path Bluetooth/AVRCP buttons
# use), the gapless move to the next track and playback resumption after the
# process died. These are what unit tests can't catch, see CLAUDE.md.
#
# Needs a booted emulator with the app logged in (a fresh install can log in
# with --login). Plays the first album on the home screen.
#
#   tool/emulator_check.sh            # install the APK in build/ and check
#   tool/emulator_check.sh --build    # build the release APK first
#   tool/emulator_check.sh --apk x.apk   # e.g. a known-good build to compare
#   tool/emulator_check.sh --no-install  # check what's installed
#   VOIDWEAVER_URL=https://... VOIDWEAVER_USER=... VOIDWEAVER_PASSWORD=... \
#     tool/emulator_check.sh --login  # log in on a fresh install first
#
# Exits non-zero if a check fails.

set -uo pipefail

SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
PKG=red.ochsenbein.voidweaver
APK=build/app/outputs/flutter-apk/app-release.apk
build=false install=true login=false

while [ $# -gt 0 ]; do
  case "$1" in
    --build) build=true ;;
    --apk) APK="$2"; shift ;;
    --no-install) install=false ;;
    --login) login=true ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

cd "$(dirname "$0")/.."

failures=0
pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; failures=$((failures + 1)); }
step() { echo; echo "== $1"; }
key() { "$ADB" shell input keyevent "$1"; }

# The app's sessions in `dumpsys media_session`, one block each
sessions() {
  "$ADB" shell dumpsys media_session | grep -A12 "package=$PKG"
}
session_count() { "$ADB" shell dumpsys media_session | grep -c "package=$PKG"; }
session_active() { sessions | grep -m1 -o 'active=[a-z]*' | cut -d= -f2; }
# PLAYING, PAUSED, NONE, ...
session_state() {
  sessions | grep -m1 -o 'state=PlaybackState {state=[A-Z_]*' | sed 's/.*state=//'
}
# "title, artist, album"
session_title() {
  sessions | grep -m1 -o 'description=.*' | sed 's/description=//' | tr -d '\r'
}
app_pid() { "$ADB" shell pidof "$PKG" | tr -d '\r'; }

# Waits up to $2 seconds (default 15) for the session to be in state $1
wait_state() {
  local want="$1" timeout="${2:-15}" i
  for ((i = 0; i < timeout * 2; i++)); do
    [ "$(session_state)" = "$want" ] && return 0
    sleep 0.5
  done
  return 1
}

# Waits up to $2 seconds for the title to differ from $1
wait_title_change() {
  local from="$1" timeout="${2:-15}" i
  for ((i = 0; i < timeout * 2; i++)); do
    local now
    now="$(session_title)"
    [ -n "$now" ] && [ "$now" != "$from" ] && return 0
    sleep 0.5
  done
  return 1
}

expect_state() {
  local want="$1" what="$2"
  if wait_state "$want"; then
    pass "$what: $want"
  else
    fail "$what: expected $want, got '$(session_state)' (active=$(session_active))"
  fi
}

# `input text` needs spaces as %s and shell metacharacters escaped
type_text() {
  local escaped
  escaped="$(printf '%s' "$1" | sed -e 's/[][\\&|;<>()$`"'"'"'*?~#!{}]/\\&/g' -e 's/ /%s/g')"
  "$ADB" shell input text "$escaped"
}

"$ADB" get-state >/dev/null 2>&1 || { echo "No device. Start the emulator first (see CLAUDE.md)." >&2; exit 2; }

if $build; then
  step "Building release APK"
  flutter build apk --release || exit 1
fi

if $install; then
  step "Installing $APK"
  [ -f "$APK" ] || { echo "No APK at $APK, run with --build." >&2; exit 2; }
  "$ADB" install -r "$APK" >/dev/null || { echo "Install failed" >&2; exit 1; }
  pass "installed"
fi

step "Starting the app"
"$ADB" shell am start -n "$PKG/.MainActivity" >/dev/null
sleep 5

if $login; then
  : "${VOIDWEAVER_URL:?set VOIDWEAVER_URL}" "${VOIDWEAVER_USER:?set VOIDWEAVER_USER}"
  : "${VOIDWEAVER_PASSWORD:?set VOIDWEAVER_PASSWORD}"
  step "Logging in"
  # Coordinates and key sequence from CLAUDE.md (1080x2400)
  "$ADB" shell input tap 540 1186
  type_text "$VOIDWEAVER_URL"
  key 61
  type_text "$VOIDWEAVER_USER"
  key 61
  type_text "$VOIDWEAVER_PASSWORD"
  key 66
  sleep 1
  "$ADB" shell input tap 540 1817
  sleep 8
fi

step "Playback from the app"
"$ADB" shell input tap 400 550   # first album card, below the list order toggle
expect_state PLAYING "after tapping the first album"
if [ "$(session_active)" = true ]; then pass "session active"; else fail "session not active (active=$(session_active))"; fi
count="$(session_count)"
if [ "$count" = 1 ]; then pass "one session"; else fail "$count sessions, expected 1"; fi
title="$(session_title)"
if [ -n "$title" ]; then pass "metadata: $title"; else fail "no metadata in the session"; fi

notification="$("$ADB" shell dumpsys notification --noredact | grep -A40 "pkg=$PKG")"
if echo "$notification" | grep -q 'category=transport' &&
  echo "$notification" | grep -q 'Notification$MediaStyle'; then
  pass "media notification posted"
else
  fail "no media notification (MediaStyle, category=transport)"
fi

step "Media keys"
key KEYCODE_MEDIA_PAUSE;      expect_state PAUSED  "MEDIA_PAUSE"
key KEYCODE_MEDIA_PLAY;       expect_state PLAYING "MEDIA_PLAY"
key KEYCODE_MEDIA_PLAY_PAUSE; expect_state PAUSED  "MEDIA_PLAY_PAUSE"
key KEYCODE_MEDIA_PLAY_PAUSE; expect_state PLAYING "MEDIA_PLAY_PAUSE"

title="$(session_title)"
key KEYCODE_MEDIA_NEXT
if wait_title_change "$title"; then
  pass "MEDIA_NEXT: $(session_title)"
else
  fail "MEDIA_NEXT: title stayed '$title'"
fi
expect_state PLAYING "after MEDIA_NEXT"
# Within the first seconds of a track, Previous goes back a track rather
# than restarting it
next_title="$(session_title)"
sleep 1   # past the skip debounce
key KEYCODE_MEDIA_PREVIOUS
if wait_title_change "$next_title" && [ "$(session_title)" = "$title" ]; then
  pass "MEDIA_PREVIOUS: $(session_title)"
else
  fail "MEDIA_PREVIOUS: expected '$title', got '$(session_title)'"
fi
expect_state PLAYING "after MEDIA_PREVIOUS"

step "Gapless move to the next track"
title="$(session_title)"
"$ADB" shell input tap 1035 1903   # end of the seek bar: the last seconds
if wait_title_change "$title" 30; then
  pass "moved on to: $(session_title)"
else
  fail "still on '$title' after seeking to its end"
fi
expect_state PLAYING "after the track ended"

step "Playback resumption after the process died"
key KEYCODE_MEDIA_PAUSE
expect_state PAUSED "paused"
title="$(session_title)"
old_pid="$(app_pid)"
key KEYCODE_APP_SWITCH
sleep 2
"$ADB" shell input swipe 540 1300 540 150 300   # swipe the app away
sleep 1
key KEYCODE_HOME
sleep 1
# Not `am force-stop`: it disables the app's receivers
for _ in $(seq 1 10); do
  [ -z "$(app_pid)" ] && break
  "$ADB" shell am kill "$PKG"
  sleep 1
done
if [ -z "$(app_pid)" ]; then
  pass "process gone (was $old_pid)"
  key KEYCODE_MEDIA_PLAY
  if wait_state PLAYING 20; then
    pass "MEDIA_PLAY started a new process ($(app_pid)) that plays"
  else
    fail "MEDIA_PLAY: no playback (state '$(session_state)', pid '$(app_pid)')"
  fi
  if [ "$(session_title)" = "$title" ]; then
    pass "resumed the saved track: $title"
  else
    fail "resumed '$(session_title)', expected '$title'"
  fi
  sleep 2   # until the `resume` stand-in is released
  count="$(session_count)"
  if [ "$count" = 1 ]; then pass "one session"; else fail "$count sessions, expected 1"; fi
else
  fail "process still running after am kill"
fi

step "Errors in the log"
pid="$(app_pid)"
if [ -n "$pid" ]; then
  # The app's warnings and errors (Dart's `W/`/`S/` through the flutter tag,
  # the plugin's tags) and exceptions, without the system's noise
  errors="$("$ADB" logcat -d --pid="$pid" |
    grep -E " flutter *: [WS]/| [EW] (MediaCache|PlaybackService|VoidweaverGain|AndroidRuntime) *:|Exception" || true)"
  if [ -z "$errors" ]; then
    pass "no warnings or errors from the app"
  else
    # Not a failure by itself, but worth reading
    echo "$errors" | tail -20 | sed 's/^/  log   /'
  fi
fi

key KEYCODE_MEDIA_PAUSE

echo
if [ "$failures" -eq 0 ]; then
  echo "All checks passed."
else
  echo "$failures check(s) failed."
  exit 1
fi
