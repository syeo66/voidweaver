# Development

## Commands

```bash
make setup           # flutter pub get
make run             # run on device/emulator (prefer the Android emulator)
make test            # flutter test
make analyze         # flutter analyze (keep it at 0 issues)
make format          # dart format lib/ test/
make build-release   # format + analyze + test + release APK
make lint-android    # Android Lint on the player plugin (Gradle, needs JAVA_HOME)
make test-integration  # user flows on a device/emulator against a fake server (see test/README.md)
make check-apk       # release APK, then checks it for shrunk-away notification icons, media session and widget entries (tool/check_release_apk.sh, no device)
make check-emulator  # release APK, then media session/keys/resumption checks in the running emulator (tool/emulator_check.sh, see docs/ANDROID.md)
make check-emulator-fake  # the same against the fake Subsonic server, no login needed; clears the app's data (also nightly in CI)
```

Regenerate mocks after changing a `@GenerateMocks` annotation:

```bash
dart run build_runner build
```

CI regenerates them and fails if `test/` differs from what's committed (also a generated file that's missing), so commit the regenerated files.

## Server setup for development

The app is meant to run against Navidrome behind [subsoxy](https://github.com/syeo66/subsoxy), see the [README](../README.md#setup). Subsonic servers report errors (wrong password, unknown id) as HTTP 200 with `status="failed"`; `SubsonicApi.parseResponse()` turns those into a `SubsonicException`. The app only accepts `https://` URLs (checked in `Validators` and the `SubsonicApi` constructor), so even locally you need a TLS-terminating proxy in front of subsoxy.

Endpoints used: `ping` (checks the credentials on login), `getAlbumList2` (`type=recent` or `type=newest`, the home screen's "Recently played"/"Recently added" toggle, saved in `SettingsService.albumListType`), `getScanStatus` (whether the library changed, see [CACHING.md](CACHING.md)), `getAlbum`, `getArtists`, `getArtist`, `search3`, `getRandomSongs`, `scrobble`, `stream`, `download` (only the start of the file, for ReplayGain tags the server doesn't report, see [REPLAYGAIN.md](REPLAYGAIN.md#where-the-values-come-from)), `getCoverArt`. subsoxy changes the behavior of `getRandomSongs` and `scrobble`. Everything else passes through to Navidrome.

## Layout

| Path | Purpose |
|------|---------|
| `lib/services/app_state.dart` | App-wide state: login, creates the API and player services, background sync while the app is visible, see [CACHING.md](CACHING.md) |
| `lib/services/subsonic_api.dart` | Subsonic client: token auth, response parsing, API cache. Re-exports the models from `lib/models/subsonic_models.dart` |
| `lib/services/audio_player_service.dart`, `player_worker.dart` | The playlist and the player: skips, load errors, scrobbling, ReplayGain gains; the worker carries out every change of the player's track, sequence or position one call at a time. See [PLAYBACK.md](PLAYBACK.md) |
| `lib/services/upcoming_downloads.dart`, `replaygain_resolver.dart`, `listening_tracker.dart`, `sleep_timer.dart` | Parts of the player service: downloads of the next tracks ([CACHING.md](CACHING.md)), where a song's ReplayGain comes from ([REPLAYGAIN.md](REPLAYGAIN.md)), the listening time per play, the sleep timer |
| `packages/voidweaver_player/` | Local plugin: playlist player on Media3 ExoPlayer with a gain stage per item, the media session for notification, lock screen and Bluetooth controls, the home screen widget (`PlayerWidget`, see [ANDROID.md](ANDROID.md#home-screen-widget)), the audio cache, network events (Java on the Android side) |
| `lib/services/api_cache.dart`, `audio_cache.dart`, `image_cache_manager.dart`, `cover_art_cache.dart` | Caching, see [CACHING.md](CACHING.md) |
| `lib/services/launcher_shortcuts.dart` | The Random launcher shortcut: whether it was tapped, asked by `AppRouter` (`lib/main.dart`); the native side is `MainActivity`, see [ANDROID.md](ANDROID.md#launcher-shortcut) |
| `lib/services/scrobble_queue.dart` | Persistent scrobble queue with retries, see [PLAYBACK.md](PLAYBACK.md#scrobbling) |
| `lib/services/replaygain_reader.dart`, `lib/services/replaygain/` | ReplayGain tag reading, one parser per tag format, see [REPLAYGAIN.md](REPLAYGAIN.md) |
| `lib/services/playback_persistence.dart` | Saves and restores queue and position, see [PLAYBACK.md](PLAYBACK.md#restoring-playback) |
| `lib/services/network_*.dart` | Timeout presets, retry with backoff, user-facing error messages |
| `lib/services/error_handler.dart`, `lib/widgets/error_boundary.dart` | Global error handler and `ErrorBoundary` / `.withErrorBoundary()` widgets |

State is managed with Provider. Services take optional dependencies (`VoidweaverPlayer`, `ScrobbleQueue`, `AudioCache`) so tests can inject fakes.

## Conventions

- Logging has its own section: [Logging](#logging), with the [session log](#session-log) users can send.
- Every service and `State` that owns subscriptions, timers, controllers or HTTP clients disposes them in `dispose()`. `test/services/memory_leak_test.dart` covers the services.
- Per-login state lives on the login's objects (`SubsonicApi`, the player service), not in statics: a static that says "the current login" would be set by `AppState` and break tests that run several. The singletons that remain are process-wide by nature: `ErrorHandler` (it owns `FlutterError.onError`) and `SessionLog` (one file).
- User-visible changes get a line under `## Unreleased` in `CHANGELOG.md`, see [RELEASING.md](RELEASING.md).
- Check `mounted` after `await` in widgets.
- Screens choose layouts with `MediaQuery.of(context).orientation`, using `_buildPortraitLayout()` / `_buildLandscapeLayout()`. Test both orientations when changing a screen.
- Wrap independent screen sections in `.withErrorBoundary()`.
- Screens stay thin: their sections and dialogs live in `lib/widgets/` (`now_playing_view.dart`, `playlist_strip.dart`, `sleep_timer_dialog.dart`, and the Settings sections in `lib/widgets/settings/`).
- Everything tappable needs a label a screen reader can read, a tap target of at least 48 dp, and readable text contrast, in both themes. Give `IconButton`s a `tooltip`. Don't put a bare `Radio` in a `ListTile` (it's announced without its title): use `RadioListTile`. `test/screens/accessibility_test.dart` checks the home, Now Playing, Settings and login screens against Flutter's guidelines; a new screen or Settings section goes there.
- The analyzer runs with `strict-casts`, `strict-raw-types`, `strict-inference`, `discarded_futures` and `unawaited_futures`. Cast JSON values explicitly (`json['id'] as String?`), give type arguments where nothing infers them (`Future<void>.delayed(...)`, `MaterialPageRoute<void>(...)`), and mark fire-and-forget futures with `unawaited(...)`, adding `.catchError` when a failure needs more than the zone's error report.
- Let exceptions keep their type (rethrow rather than wrapping them in `Exception('...: $e')`) and show them with `NetworkErrorHelper.getErrorMessage(e, context: '...')`, never with `toString()`. Throw `UserFacingException` for errors whose message is meant for the user.
- Format durations and sizes with `lib/utils/format.dart`: `formatClock()` for playback times and track lengths (`3:05`), `formatHoursMinutes()` for longer spans (`1h 5m`), `formatBytes()`.
- `AudioPlayerService` doesn't notify its listeners for position updates (several a second). Widgets that show the position listen to `AudioPlayerService.position`.
- The server can reject the saved credentials (a changed password); requests the app makes on its own then stop. Read [Rejected credentials](#rejected-credentials) before adding one.

## Logging

- Log through a `Logger` from `package:logging`, one per file (`final _log = Logger('api_cache');`), not `debugPrint()` or `print()`.
- Levels: `severe` for unexpected errors, `warning` for failures the app recovers from, `info` for notable events, `fine` for details.
- Pass the error as the second argument (`_log.warning('Search failed', e)`), and the stack trace as the third for `severe` and for errors that point to a bug rather than to the network or storage (`catch (e, stack)`). Pass a closure for messages that are expensive to build (`_log.fine(() => doc.toXmlString())`).
- `setUpLogging()` in `lib/utils/log.dart` prints all records through `redactCredentials()`, so URLs can be logged as they are.
- Debug builds print every level, release builds `info` and up. Build with `--dart-define=LOG_LEVEL=FINE` for everything, or `--dart-define=LOG_FINE=audio_player,replaygain` for some loggers only. On Android the lines appear as `I flutter : W/api_cache: ...` (`adb logcat -s flutter`). Tests print nothing.
- Log at `fine` with care: nothing per position update or per frame, since the session log below is written in release builds too.

### Session log

`lib/services/session_log.dart`: every record from `fine` up, whatever the console prints, also in release builds, goes to `session.log` in the app's documents directory, for users to send (Settings → Session Log → Export, through the share sheet). Nothing leaves the device.

- Each start moves the last run's file to `session.previous.log`, replacing the one before, and starts a new one with a header (app version, OS, start time). So the log holds this run and the previous one, which a process killed in the background or a crash would otherwise lose.
- Lines logged before the file is open are kept in memory and written after the header.
- Over 5 MB the file starts over, with the header again and a note.
- Lines go through `formatLogRecord()`, so credentials are redacted.
- Native messages (ExoPlayer, Media3) aren't in it: logcat only.

**How earlier runs ended.** At the start of every run, `logPreviousRunEnd()` (`lib/services/previous_run.dart`) logs how earlier runs ended, from the plugin's `ProcessHistory`. It has two sources:

- The stack of an uncaught Java exception, which the plugin saves to a file before the process dies (`ProcessHistory.installCrashRecorder()`, installed with the plugin and in `PlaybackService`).
- On Android 11 and newer, Android's own record of why a process ended (`ApplicationExitInfo`: low memory, ANR, native crash, force stop).

Each entry is reported once and comes right after the header, next to `session.previous.log`, which stops at the kill; a Java crash gives two entries, the saved stack and Android's exit record. Crashes and kills of a process that was playing are warnings; a user's stop and the cleanup of a cached process are info.

## Rejected credentials

When the server rejects the saved credentials (an auth error from any request, also the scrobble queue's retries), `SubsonicApi.credentialsRejected` is set and the home screen shows `CredentialsBanner`, which asks for the new password.

**Entering the new password** (`AppState.updatePassword()`):

- It checks the password with a `ping`, saves it, and hands it to the existing `SubsonicApi` (`usePassword()`). So playback goes on, and the pending scrobbles, the saved queue and the caches stay, which a logout would drop.
- The player's items still carry stream URLs with the old password: `AudioPlayerService.credentialsChanged()` restarts the downloads of the upcoming tracks, and an item that fails to stream loads the queue again with new URLs at that track.
- Any other answer from the server clears the flag.

**While the flag is set, nothing is sent on its own** (`SubsonicApi.hasRejectedCredentials`):

- The scrobble queue holds its requests (submissions and "now playing"), which keep their times, see [PLAYBACK.md](PLAYBACK.md#scrobbling).
- Background sync skips, and downloads of upcoming tracks stop.
- ReplayGain tags aren't read from the server (`SubsonicApi.readReplayGain()`, also for a track the user starts: it plays at the fallback gain, its stream still goes out).
- Cover art that isn't cached isn't fetched (`CoverArtFileService`, see [CACHING.md](CACHING.md#cover-art-imagecachemanager)); a cover refused for the credentials sets the flag too. The media session still loads the artwork of a track that plays, unless it's cached: one request per track, like its stream. The home screen widget loads it again after a load that didn't reach the server (no connection, a timeout), at most 3 times per cover, and stops at the server's first error answer, see [ANDROID.md](ANDROID.md#home-screen-widget).

Each request would fail the same way, and a steady stream of failed logins can get the device banned (fail2ban in front of the server), which would then refuse the new password too. Requests the user starts (a refresh, an album) still go out, so a password changed back on the server clears the flag.

## Playback internals

How the player's queue is followed, downloads swapped in, load errors, skips, system controls and audio focus are described in [PLAYBACK.md](PLAYBACK.md). Read it before changing `audio_player_service.dart` or the plugin.

## Android

Testing the native layer (media session, notification, media keys, R8) in the emulator, the setup it needs, and known pitfalls are in [ANDROID.md](ANDROID.md).

- `MainActivity` gets its `FlutterEngine` from the plugin's `AppEngine`, which keeps it cached so Dart keeps running without the activity. `PlaybackService` starts the same engine without an activity to resume playback for a media button (see [PLAYBACK.md](PLAYBACK.md#bluetooth-and-system-controls)). It must not request audio focus (see [PLAYBACK.md](PLAYBACK.md#audio-focus)).
- Backups are off (`allowBackup="false"` and `res/xml/data_extraction_rules.xml`, which explains why).
- The plugin's manifest declares `PlaybackService` (`foregroundServiceType="mediaPlayback"`) and its permissions; it's merged into the app's.
- Versioning: the version name comes from `pubspec.yaml`, where `tool/release.sh` bumps it (`make deploy-patch`, see [RELEASING.md](RELEASING.md)). The build number (`versionCode`) is the git commit count (`android/app/build.gradle.kts`), so CI checks out the full history. Settings shows both at the bottom.
- The release APK is arm64 only: build it through `tool/build_release_apk.sh` (CI, the Makefile and `tool/emulator_check.sh` do), never a plain `flutter build apk`, which makes it nearly three times as large. `tool/check_release_apk.sh` fails on such an APK.
- Flutter version: CI installs the SDK version in `.flutter-version`, one line for every job of both workflows (`.github/actions/setup-flutter`). Dependabot can't bump it; change it by hand. `pubspec.yaml` deliberately has no exact `environment: flutter:` pin, which would stop `flutter pub get` on any other local version.
- CI: its actions are pinned to commit SHAs, also inside the composite action, see the comments in `.github/workflows/flutter.yml`; pin new ones the same way. The player plugin's JVM tests and Android Lint run in their own job (`android-unit-tests`). Pull requests that change Media3, AGP or Kotlin need the emulator checks above. `.github/workflows/nightly.yml` runs the randomized playback test, the integration tests and the release-build checks every night, see [test/README.md](../test/README.md#nightly-checks).

## Tests

See [test/README.md](../test/README.md).
