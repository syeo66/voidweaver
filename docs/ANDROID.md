# Android: native layer and emulator testing

Unit tests can't catch problems in the native Android layer: the media session, the notification, Bluetooth/media buttons, R8 and resource shrinking. Verify anything touching `android/`, Gradle/AGP/Kotlin versions, or `packages/voidweaver_player/` (or its Media3 version) in the emulator with a **release** build, as described below. How the session and system controls work is described in [PLAYBACK.md](PLAYBACK.md#bluetooth-and-system-controls).

## Environment

- Gradle needs a JDK. Android Studio ships one; on macOS: `export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`.
- The Android SDK is expected at `~/Library/Android/sdk` (the scripts honor `ANDROID_SDK_ROOT`). `adb`, `emulator`, and `apkanalyzer`/`sdkmanager`/`avdmanager` live under `platform-tools/`, `emulator/` and `cmdline-tools/*/bin/`; `aapt2` lives under `build-tools/<version>/`.
- The scripts and the coordinates below assume a 1080x2400 screen, e.g. a Pixel 8 AVD (Android 16, arm64) or the `pixel_6` profile (same screen).

## Running the app in the emulator

```bash
SDK=~/Library/Android/sdk; ADB=$SDK/platform-tools/adb
$SDK/emulator/emulator -avd <your AVD> -no-snapshot -no-boot-anim &   # run in background
$ADB wait-for-device; until [ "$($ADB shell getprop sys.boot_completed | tr -d '\r')" = 1 ]; do sleep 2; done

flutter build apk --release
$ADB install -r build/app/outputs/flutter-apk/app-release.apk   # -r keeps the login
$ADB shell am start -n red.ochsenbein.voidweaver/.MainActivity      # `monkey` fails on Play Store images
```

**Logging in:** the app only accepts `https://` URLs. Use your own server, or `tool/emulator_check.sh --fake-server` (below), which needs none. Never commit credentials. On a fresh install:

- tap the Server URL field at (540, 1186) in device pixels (1080x2400);
- type with `adb shell input text '...'`;
- move to the next field with `input keyevent 61` (Tab), not taps, because the keyboard shifts the layout;
- after the password, `input keyevent 66` (Enter) closes the keyboard; then tap Connect at (540, 1817).

Don't send Back (`keyevent 4`) when the keyboard is already hidden, because that closes the app. `adb shell pm clear red.ochsenbein.voidweaver` resets to the login screen.

After login, tapping the first album card at (400, 550) starts playback. Tapping the seek bar at (1035, 1903) jumps to the last few seconds of the track, which is how to test the gapless move to the next track and the end of the playlist.

**Offline:** `$ADB shell svc wifi disable; $ADB shell svc data disable` (`enable` to undo). The next 3 tracks are downloaded, so skip past them with `MEDIA_NEXT` to reach a track that has to stream and fails to load. Playback should stop there, paused, with the session still active; with the network back, Play loads it again.

**Network events in the emulator:** `NetworkMonitor` (and with it the resume after a network failure, and restarting downloads, see [PLAYBACK.md](PLAYBACK.md#when-the-network-comes-back)) only reacts to a *validated* default network. In the AVD no network passes Android's internet check, so it never fires, whatever you toggle (`dumpsys connectivity`: no `VALIDATED` in the network's capabilities; the default network is mobile data, so toggling Wi-Fi doesn't even change it). To test it, turn the check off with `$ADB shell settings put global captive_portal_mode 0`, then `svc data disable` / `enable`: the network comes back validated and the app gets the event. Undo with `$ADB shell settings delete global captive_portal_mode`. The same holds on a phone: a network without internet access (e.g. Wi-Fi with only the home server) never counts as back.

**Screenshots:** `$ADB exec-out screencap -p > x.png`. They're 1080x2400; if you view them scaled down, scale the coordinates back up before tapping.

## Checking the media session, notification and Bluetooth controls

This is the part most likely to break silently.

`tool/check_release_apk.sh` checks the release APK itself, without a device: Media3's notification icons are there and not shrinker placeholders, the manifest declares `PlaybackService` and the media button receiver, and their classes survived R8. CI runs it after the release build; `make check-apk` builds and runs it. It catches the shrinker failure described under [Known pitfalls](#known-pitfalls), but not a session that's broken at runtime.

`tool/emulator_check.sh` runs the checks below (session, notification, media keys, gapless move to the next track, playback resumption, app errors in logcat) against a booted emulator with the app logged in, and exits non-zero on a failure. It waits for screens and taps elements through `uiautomator` rather than fixed delays, stops early when the app, the login or the first playback fails, and saves a screenshot, the UI hierarchy and logcat to `build/emulator-check/diagnostics/`. `make check-emulator` builds the release APK first; `--apk <file>` installs another build, e.g. a known-good one to compare. Run it after every change to playback, login, the native layer or the toolchain. `make check-emulator-fake` (`--fake-server --build`) needs no server or credentials: it builds a release APK that trusts the tests' fake Subsonic server, runs that server on the host, clears the app's data and logs in to it. CI doesn't run it (it failed at the login step in the runner's emulator), so run it locally. The trusting APK goes to `build/emulator-check/`; never install it anywhere else.

The manual steps below are for investigating when it fails, and for what it doesn't cover (offline, untrusted controllers).

```bash
$ADB shell dumpsys media_session | grep -A12 "package=red.ochsenbein.voidweaver" | grep -E "active=|state=PlaybackState|description="
$ADB shell input keyevent KEYCODE_MEDIA_PAUSE     # also MEDIA_PLAY, MEDIA_NEXT, MEDIA_PREVIOUS,
$ADB shell input keyevent KEYCODE_MEDIA_PLAY_PAUSE # MEDIA_PLAY_PAUSE (= headset button)
$ADB shell cmd statusbar expand-notifications      # then screenshot; `collapse` to close
```

Media key events go through MediaSessionService to the active session, the same path Bluetooth/AVRCP buttons use.

- **Healthy:** `active=true`, the state follows the keys (`PLAYING(3)` / `PAUSED(2)`), and the shade shows the media player with artwork.
- **Broken:** `active=false` with `state=NONE(0)` while audio plays.

**Playback resumption** (Play after the process died): start playback with the app's Play button (Android only sends media keys to a session that has played audio), pause, swipe the app away in Recents (`input keyevent KEYCODE_APP_SWITCH`, then `input swipe 540 1300 540 150 300`), go Home and run `$ADB shell am kill red.ochsenbein.voidweaver` until `pidof` prints nothing. Don't use `am force-stop`: it disables the app's receivers. Then `input keyevent KEYCODE_MEDIA_PLAY` should start a new process that plays the saved track within seconds, with a single session in `dumpsys media_session`: the `resume` session, which the app's player took over. `Media button session is` must name it; if it says `null`, only Play reaches the app (`MediaButtonReceiver: Ignore key event that is not a play command` in logcat), so check that `MEDIA_PAUSE` and `MEDIA_NEXT` still work afterwards.

**System UI's resumption controls:** after a play, logcat should show `MediaResumeListener: Testing if we can connect to …PlaybackService` without a following `Cannot resume with`, and `dumpsys activity service com.android.systemui | grep resumeAction` should show a `resumeAction` for the app. Paused for more than 10 minutes, the player in the shade then turns into resumption controls instead of disappearing.

When it's broken, check `$ADB logcat -d --pid=$($ADB shell pidof red.ochsenbein.voidweaver) | grep -E " [EW] |Exception"`.

**Compare against a known-good build.** If behavior differs, build the previous commit too and install each in turn. Diff the merged manifests (`build/app/intermediates/merged_manifest/release/...`) and the resources (`aapt2 dump resources <apk>`).

## Known pitfalls

- Plugins that load resources by name at runtime (`getIdentifier`) need keep rules, because the resource shrinker can't see those references. `audio_service` did, and AGP 9's optimized shrinking removed its notification icons, which killed the notification, lock screen player and Bluetooth controls. Media3, which replaced it, references its resources normally.
- System controls (notification, lock screen, Bluetooth/media buttons) come from the plugin's Media3 media session. `SessionPlayer` forwards every command to Dart and shows a player that's idle after a load error as paused; only `stop()` ends the notification. `MainActivity` caches its `FlutterEngine` so Dart runs without the activity. See [PLAYBACK.md](PLAYBACK.md#bluetooth-and-system-controls).
- The player is the local plugin `packages/voidweaver_player` (Media3 ExoPlayer). ReplayGain is a gain per queue item, applied to the samples by `GainAudioProcessor`, not the player volume; see [PLAYBACK.md](PLAYBACK.md#replaygain-per-track). It relies on Media3 flushing audio processors with `StreamMetadata` at item boundaries (Media3 1.11), so after a Media3 upgrade check `adb logcat -s VoidweaverGain` across a gapless transition.
- The system UI (notification, media keys) is a *trusted* controller; launcher widgets and other third-party apps are not, and Media3 limits untrusted controllers to read access unless the session grants more (`PlayerSession.Callback`). Testing with the notification alone won't catch that. To test like a widget, use a small app that's an enabled notification listener (`adb shell cmd notification allow_listener <component>`) and sends `MediaController.getTransportControls()` commands.
- Audio focus is handled by ExoPlayer in the plugin. Don't request it in `MainActivity.kt` or elsewhere, because that registers a competing listener (see the comment there and [PLAYBACK.md](PLAYBACK.md#audio-focus)).
- `gradle.properties` sets `android.builtInKotlin=false` and `android.newDsl=false` (added by the Flutter migrator). The app still applies the `kotlin-android` plugin; moving to built-in Kotlin is pending and should be its own change, verified in the emulator.
- When upgrading dependencies, bump the Dart packages and the Android toolchain (AGP/Gradle/Kotlin) in separate steps so regressions can be bisected.
