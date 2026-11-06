#!/usr/bin/env bash
# Fails if an APK is signed with the debug key (or not at all). A release
# built without the release keystore is debug-signed: installing it over a
# real release fails, so the release workflow refuses to publish it. Needs
# apksigner from the Android SDK's build-tools, no device.
#
#   tool/check_apk_signature.sh [apk]   # default build/app/outputs/flutter-apk/app-release.apk

set -uo pipefail

cd "$(dirname "$0")/.."
APK="${1:-build/app/outputs/flutter-apk/app-release.apk}"
[ -f "$APK" ] || { echo "No APK at $APK" >&2; exit 2; }

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
APKSIGNER=$(ls -d "$SDK"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)
[ -x "$APKSIGNER" ] || { echo "No apksigner under $SDK/build-tools" >&2; exit 2; }

certs=$("$APKSIGNER" verify --print-certs "$APK") || { echo "$APK has no valid signature" >&2; exit 1; }
subject=$(grep -m1 'certificate DN:' <<<"$certs")
echo "$subject"
echo "$(grep -m1 'certificate SHA-256 digest:' <<<"$certs")"
if grep -q 'CN=Android Debug' <<<"$subject"; then
  echo "FAIL: signed with the debug key (set the VOIDWEAVER_KEYSTORE_* variables, see docs/RELEASING.md)" >&2
  exit 1
fi
echo "ok: signed with a release key"
