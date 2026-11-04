# Development

## Commands

```bash
make setup           # flutter pub get
make run             # run on device/emulator (prefer the Android emulator)
make test            # flutter test
make analyze         # flutter analyze (keep it at 0 issues)
make format          # dart format lib/ test/
make build-release   # format + analyze + test + release APK
make test-integration  # user flows on a device/emulator against a fake server (see test/README.md)
make check-apk       # release APK, then checks it for shrunk-away notification icons and media session entries (tool/check_release_apk.sh, no device)
make check-emulator  # release APK, then media session/keys/resumption checks in the running emulator (tool/emulator_check.sh, see docs/ANDROID.md)
make check-emulator-fake  # the same against the fake Subsonic server, no login needed; clears the app's data (local only, not in CI)
```

Regenerate mocks after changing a `@GenerateMocks` annotation:

```bash
dart run build_runner build --delete-conflicting-outputs
```

## Server setup for development

The app is meant to run against Navidrome behind [subsoxy](https://github.com/syeo66/subsoxy), see the [README](../README.md#setup). Subsonic servers report errors (wrong password, unknown id) as HTTP 200 with `status="failed"`; `SubsonicApi.parseResponse()` turns those into a `SubsonicException`. The app only accepts `https://` URLs (checked in `Validators` and the `SubsonicApi` constructor), so even locally you need a TLS-terminating proxy in front of subsoxy.

Endpoints used: `ping` (checks the credentials on login), `getAlbumList2` (`type=recent` or `type=newest`, the home screen's "Recently played"/"Recently added" toggle, saved in `SettingsService.albumListType`), `getScanStatus` (whether the library changed, see [CACHING.md](CACHING.md)), `getAlbum`, `getArtists`, `getArtist`, `search3`, `getRandomSongs`, `scrobble`, `stream`, `download` (only the start of the file, for ReplayGain tags the server doesn't report, see [REPLAYGAIN.md](REPLAYGAIN.md#where-the-values-come-from)), `getCoverArt`. subsoxy changes the behavior of `getRandomSongs` and `scrobble`. Everything else passes through to Navidrome.

## Layout

| Path | Purpose |
|------|---------|
| `lib/services/app_state.dart` | App-wide state: login, creates the API and player services, background sync every 5 minutes while the app is visible (`setVisible()`, driven by `AppRouter`'s lifecycle listener) |
| `lib/services/subsonic_api.dart` | Subsonic client: token auth, response parsing, API cache. Re-exports the models (`Album`, `Song`, `Artist`, `SearchResult`) from `lib/models/subsonic_models.dart` |
| `lib/services/audio_player_service.dart` | Hands the playlist to the player and follows it; skips, load errors, ReplayGain gains, scrobbling, prefetching |
| `lib/services/listening_tracker.dart`, `sleep_timer.dart` | The player service's listening time and scrobble decision per play, and the sleep timer with its fade, see [PLAYBACK.md](PLAYBACK.md) |
| `packages/voidweaver_player/` | Local plugin: playlist player on Media3 ExoPlayer with a gain stage per item, and the Media3 media session for notification, lock screen and Bluetooth controls (Java on the Android side) |
| `lib/services/api_cache.dart`, `audio_cache.dart`, `image_cache_manager.dart` | Caching, see [CACHING.md](CACHING.md) |
| `lib/services/scrobble_queue.dart` | Persistent scrobble queue with retries |
| `lib/services/replaygain_reader.dart`, `lib/services/replaygain/` | ReplayGain tag reading: `ReplayGainReader` fetches the start of the file and parses it on a background isolate; one parser per tag format (`id3v2.dart`, `ape.dart`, `vorbis.dart`, `mp4.dart`), see [REPLAYGAIN.md](REPLAYGAIN.md) |
| `lib/services/playback_persistence.dart` | Saves and restores queue and position (separate SharedPreferences keys, so the position save every 5 s doesn't rewrite the queue) |
| `lib/services/network_*.dart` | Timeout presets, retry with backoff, user-facing error messages |
| `lib/services/error_handler.dart`, `lib/widgets/error_boundary.dart` | Global error handler and `ErrorBoundary` / `.withErrorBoundary()` widgets |

State is managed with Provider. Services take optional dependencies (`VoidweaverPlayer`, `ScrobbleQueue`, `AudioCache`) so tests can inject fakes.

## Conventions

- Log through a `Logger` from `package:logging`, one per file (`final _log = Logger('api_cache');`), not `debugPrint()` or `print()`. Levels: `severe` for unexpected errors, `warning` for failures the app recovers from, `info` for notable events, `fine` for details. Pass the error as the second argument (`_log.warning('Search failed', e)`), and a closure for messages that are expensive to build (`_log.fine(() => doc.toXmlString())`). `setUpLogging()` in `lib/utils/log.dart` prints all records through `redactCredentials()`, so URLs can be logged as they are.
- Debug builds print every level, release builds `info` and up. Build with `--dart-define=LOG_LEVEL=FINE` for everything, or `--dart-define=LOG_FINE=audio_player,replaygain` for some loggers only. On Android the lines appear as `I flutter : W/api_cache: ...` (`adb logcat -s flutter`). Tests print nothing.
- Every service and `State` that owns subscriptions, timers, controllers or HTTP clients disposes them in `dispose()`. `test/services/memory_leak_test.dart` covers the services.
- Check `mounted` after `await` in widgets.
- Screens choose layouts with `MediaQuery.of(context).orientation`, using `_buildPortraitLayout()` / `_buildLandscapeLayout()`. Test both orientations when changing a screen.
- Wrap independent screen sections in `.withErrorBoundary()`.
- The analyzer runs with `strict-casts`, `strict-raw-types`, `discarded_futures` and `unawaited_futures`. Cast JSON values explicitly (`json['id'] as String?`), and mark fire-and-forget futures with `unawaited(...)`, adding `.catchError` when a failure needs more than the zone's error report.
- When the server rejects the saved credentials (an auth error from any request, also the scrobble queue's retries), `SubsonicApi.credentialsRejected` is set and the home screen shows `CredentialsBanner`, which asks for the new password (`AppState.updatePassword()`). That checks it with a `ping`, saves it, and hands it to the existing `SubsonicApi` (`usePassword()`), so playback goes on and the pending scrobbles, the saved queue and the caches stay, which a logout would drop. The player's items still carry stream URLs with the old password: `AudioPlayerService.credentialsChanged()` restarts the downloads of the upcoming tracks, and an item that fails to stream loads the queue again with new URLs at that track. Any other answer from the server clears the flag.
- Let exceptions keep their type (rethrow rather than wrapping them in `Exception('...: $e')`) and show them with `NetworkErrorHelper.getErrorMessage(e, context: '...')`, never with `toString()`. Throw `UserFacingException` for errors whose message is meant for the user.
- Format durations and sizes with `lib/utils/format.dart`: `formatClock()` for playback times and track lengths (`3:05`), `formatHoursMinutes()` for longer spans (`1h 5m`), `formatBytes()`.
- Screens stay thin: their sections and dialogs live in `lib/widgets/` (`now_playing_view.dart`, `playlist_strip.dart`, `sleep_timer_dialog.dart`, and the Settings sections in `lib/widgets/settings/`).
- `AudioPlayerService` doesn't notify its listeners for position updates (several a second). Widgets that show the position listen to `AudioPlayerService.position`.

## Playback internals

How the player's queue is followed, downloads swapped in, load errors, skips, system controls and audio focus are described in [PLAYBACK.md](PLAYBACK.md). Read it before changing `audio_player_service.dart` or the plugin.

## Android

Testing the native layer (media session, notification, media keys, R8) in the emulator, the setup it needs, and known pitfalls are in [ANDROID.md](ANDROID.md).

- `MainActivity` gets its `FlutterEngine` from the plugin's `AppEngine`, which keeps it cached so Dart keeps running without the activity. `PlaybackService` starts the same engine without an activity to resume playback for a media button (see [PLAYBACK.md](PLAYBACK.md#bluetooth-and-system-controls)). It must not request audio focus (see [PLAYBACK.md](PLAYBACK.md#audio-focus)).
- Backups are off: `allowBackup="false"`, plus `res/xml/data_extraction_rules.xml` because on Android 12+ `allowBackup` alone doesn't stop the transfer to a new device. The credentials are encrypted with a Keystore key that never leaves the device, so a restored copy can't be read. The settings share one SharedPreferences file with the saved queue and pending scrobbles, so they can't be backed up on their own.
- The plugin's manifest declares `PlaybackService` (`foregroundServiceType="mediaPlayback"`) and its permissions; it's merged into the app's.
- Versioning: the version name (`1.1.0`) comes from `pubspec.yaml` and is bumped by hand. The build number (`versionCode`) is the git commit count, set in `android/app/build.gradle.kts`, so it rises with every commit; the pubspec's `+N` or `--build-number` only wins if it's higher. CI checks out the full history for this. Settings shows both at the bottom.

## Tests

See [test/README.md](../test/README.md).
