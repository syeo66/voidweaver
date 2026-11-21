#!/usr/bin/env bash
# Builds the release APK, for arm64 only: a plain `flutter build apk` also
# packs the native code for 32-bit ARM and x86_64, which phones running the
# app don't need and which makes the APK nearly three times as large. The
# one place that decides what the release APK holds: CI, the Makefile and
# tool/emulator_check.sh build through it. tool/check_release_apk.sh checks
# the result. Extra arguments go to `flutter build apk`; it runs from the
# repository root, so paths in them are relative to the root.
#
#   tool/build_release_apk.sh
#   tool/build_release_apk.sh -PtrustFakeServer=true --dart-define=...
#
# The APK lands at build/app/outputs/flutter-apk/app-release.apk.
#
# RELEASE_TARGET_PLATFORM=android-x64 builds for x86_64 instead, only for
# tool/emulator_check.sh on an x86_64 emulator (the nightly workflow's): R8,
# the manifest and the resources are the same for every ABI, so that build
# checks what the arm64 one ships. Never release it.

set -euo pipefail

cd "$(dirname "$0")/.."
flutter build apk --release \
  --target-platform "${RELEASE_TARGET_PLATFORM:-android-arm64}" "$@"
