#!/usr/bin/env bash
# Checks a release APK for what R8 and the resource shrinker can break
# silently: the resources Media3's notification uses (the notification, lock
# screen player and Bluetooth controls die without them, see
# docs/ANDROID.md), and the manifest entries and classes of the media
# session. Needs no device and no Java, only aapt2 from the Android SDK's
# build-tools, so CI runs it after the release build. It doesn't replace
# tool/emulator_check.sh.
#
#   tool/check_release_apk.sh            # build/app/outputs/flutter-apk/app-release.apk
#   tool/check_release_apk.sh some.apk
#
# Exits non-zero if a check fails.

set -uo pipefail

cd "$(dirname "$0")/.."
APK="${1:-build/app/outputs/flutter-apk/app-release.apk}"
[ -f "$APK" ] || { echo "No APK at $APK" >&2; exit 2; }

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
AAPT2=$(ls -d "$SDK"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1)
[ -x "$AAPT2" ] || { echo "No aapt2 under $SDK/build-tools" >&2; exit 2; }

failures=0
pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; failures=$((failures + 1)); }

resources=$("$AAPT2" dump resources "$APK") || { echo "aapt2 could not read $APK" >&2; exit 2; }
manifest=$("$AAPT2" dump xmltree --file AndroidManifest.xml "$APK") || exit 2
# "size path" of every file in the APK
files=$(unzip -l "$APK" | awk 'NF >= 4 && $1 ~ /^[0-9]+$/ {print $1, $4}')

# The value lines of resource [type/name] in the dump
values() {
  awk -v want="$1" '
    $1 == "resource" { inside = ($3 == want); next }
    $1 == "type" { inside = 0; next }
    inside { print }
  ' <<<"$resources"
}

# A shrinker that thinks a resource is unused can drop it, or keep the entry
# and replace its file with a placeholder of a few dozen bytes. Real icons are
# several hundred bytes or more.
MIN_FILE_BYTES=150

# Whether [type/name] exists and every file it has (following aliases like
# @drawable/x) is real content
check_resource() {
  local res="$1" depth="${2:-0}" lines alias file size ok=true
  lines=$(values "$res")
  if [ -z "$lines" ]; then
    echo "missing"
    return 1
  fi
  alias=$(grep -o '@[a-z]*/[A-Za-z0-9_.]*' <<<"$lines" | head -1)
  if [ -n "$alias" ]; then
    [ "$depth" -lt 5 ] || { echo "alias loop"; return 1; }
    check_resource "${alias#@}" $((depth + 1))
    return $?
  fi
  while read -r file; do
    size=$(awk -v f="$file" '$2 == f {print $1}' <<<"$files")
    if [ -z "$size" ]; then
      echo "$file is not in the APK"
      ok=false
    elif [ "$size" -lt "$MIN_FILE_BYTES" ]; then
      echo "$file is $size bytes (placeholder?)"
      ok=false
    fi
  done < <(grep -o '(file) [^ ]*' <<<"$lines" | cut -d' ' -f2)
  $ok
}

echo "== Resources ($APK)"
# The small icon of the notification, and the buttons Media3 shows in it.
# Update the list when Media3 renames them (check `aapt2 dump resources`).
for res in \
  drawable/media3_notification_small_icon \
  drawable/media3_icon_play \
  drawable/media3_icon_pause \
  drawable/media3_icon_next \
  drawable/media3_icon_previous \
  mipmap/launcher_icon; do
  if problem=$(check_resource "$res"); then pass "$res"; else fail "$res: $problem"; fi
done

echo
echo "== Manifest"
# The attributes and children of the element named [name], up to the next
# element at its level or above
element() {
  awk -v want="\"$1\"" '
    /E: / {
      depth = index($0, "E:")
      if (inside && depth <= start) exit
    }
    !inside && index($0, "android:name(") && index($0, "=" want) {
      inside = 1; start = prev_depth; print prev
    }
    inside { print }
    /E: / { prev = $0; prev_depth = index($0, "E:") }
  ' <<<"$manifest"
}

service=$(element red.ochsenbein.voidweaver.player.PlaybackService)
if [ -z "$service" ]; then
  fail "PlaybackService is declared"
else
  pass "PlaybackService is declared"
  # mediaPlayback = 0x2
  if grep -q 'foregroundServiceType(0x01010599)=0x0*2$' <<<"$service"; then
    pass "PlaybackService has foregroundServiceType mediaPlayback"
  else
    fail "PlaybackService has foregroundServiceType mediaPlayback"
  fi
  if grep -q '"androidx.media3.session.MediaSessionService"' <<<"$service"; then
    pass "PlaybackService is a MediaSessionService"
  else
    fail "PlaybackService is a MediaSessionService"
  fi
fi

if element androidx.media3.session.MediaButtonReceiver | grep -q '"android.intent.action.MEDIA_BUTTON"'; then
  pass "MediaButtonReceiver handles MEDIA_BUTTON (playback resumption)"
else
  fail "MediaButtonReceiver handles MEDIA_BUTTON (playback resumption)"
fi

for permission in FOREGROUND_SERVICE FOREGROUND_SERVICE_MEDIA_PLAYBACK; do
  if grep -q "=\"android.permission.$permission\"" <<<"$manifest"; then
    pass "permission $permission"
  else
    fail "permission $permission"
  fi
done

echo
echo "== Classes"
# Classes the manifest names must keep their names through R8
dex=$(unzip -p "$APK" 'classes*.dex' | LC_ALL=C tr -c '[:print:]' '\n')
for class in \
  red/ochsenbein/voidweaver/MainActivity \
  red/ochsenbein/voidweaver/player/PlaybackService \
  androidx/media3/session/MediaButtonReceiver; do
  if LC_ALL=C grep -qF "L$class;" <<<"$dex"; then pass "$class"; else fail "$class"; fi
done

echo
echo "== No trust in the fake server"
# The build of tool/emulator_check.sh --fake-server trusts the tests' fake
# Subsonic server, whose private key is public; an APK that's installed must
# not (see android/app/build.gradle.kts)
if grep -q 'networkSecurityConfig' <<<"$manifest"; then
  fail "no network security config in the manifest"
else
  pass "no network security config in the manifest"
fi
if [ -n "$(values raw/fake_subsonic_server)" ]; then
  fail "no fake server CA among the resources"
else
  pass "no fake server CA among the resources"
fi
# The CA as the VOIDWEAVER_TEST_CA define has it: "-----BEGIN CERTIFICATE"
# in base64. Counted, not grep -q: that stops reading at the first match, and
# with pipefail unzip's broken pipe would turn the match into a miss.
ca_matches=$(unzip -p "$APK" 'lib/*/libapp.so' | LC_ALL=C grep -cF 'LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0')
if [ "${ca_matches:-0}" -gt 0 ]; then
  fail "no test CA in the Dart code"
else
  pass "no test CA in the Dart code"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed"
