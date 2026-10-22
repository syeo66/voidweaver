# Development

## Commands

```bash
make setup           # flutter pub get
make run             # run on device/emulator (prefer the Android emulator)
make test            # flutter test
make analyze         # flutter analyze (keep it at 0 issues)
make format          # dart format lib/ test/
make build-release   # format + analyze + test + release APK
```

Regenerate mocks after changing a `@GenerateMocks` annotation:

```bash
dart run build_runner build --delete-conflicting-outputs
```

## Server setup for development

The app is meant to run against Navidrome behind [subsoxy](https://github.com/syeo66/subsoxy), see the [README](../README.md#setup). Subsonic servers report errors (wrong password, unknown id) as HTTP 200 with `status="failed"`; `SubsonicApi.parseResponse()` turns those into a `SubsonicException`. The app only accepts `https://` URLs (checked in `Validators` and the `SubsonicApi` constructor), so even locally you need a TLS-terminating proxy in front of subsoxy.

Endpoints used: `ping` (checks the credentials on login), `getAlbumList2` (`type=newest`), `getScanStatus` (whether the library changed, see [CACHING.md](CACHING.md)), `getAlbum`, `getArtists`, `getArtist`, `search3`, `getRandomSongs`, `scrobble`, `stream`, `getCoverArt`. subsoxy changes the behavior of `getRandomSongs` and `scrobble`. Everything else passes through to Navidrome.

## Layout

| Path | Purpose |
|------|---------|
| `lib/services/app_state.dart` | App-wide state: login, creates the API and player services, background sync every 5 minutes while the app is visible (`setVisible()`, driven by `AppRouter`'s lifecycle listener) |
| `lib/services/subsonic_api.dart` | Subsonic client: token auth, response parsing, API cache, HTTP/2 via `http_plus` |
| `lib/services/audio_player_service.dart` | Hands the playlist to the player and follows it; skips, load errors, ReplayGain gains, scrobbling, prefetching |
| `packages/voidweaver_player/` | Local plugin: playlist player on Media3 ExoPlayer with a gain stage per item, and the Media3 media session for notification, lock screen and Bluetooth controls (Java on the Android side) |
| `lib/services/api_cache.dart`, `audio_cache.dart`, `image_cache_manager.dart` | Caching, see [CACHING.md](CACHING.md) |
| `lib/services/scrobble_queue.dart` | Persistent scrobble queue with retries |
| `lib/services/replaygain_reader.dart` | ReplayGain tag parsing, see [REPLAYGAIN.md](REPLAYGAIN.md) |
| `lib/services/playback_persistence.dart` | Saves and restores queue and position (separate SharedPreferences keys, so the position save every 5 s doesn't rewrite the queue) |
| `lib/services/network_*.dart` | Timeout presets, retry with backoff, user-facing error messages |
| `lib/services/error_handler.dart`, `lib/widgets/error_boundary.dart` | Global error handler and `ErrorBoundary` / `.withErrorBoundary()` widgets |

State is managed with Provider. Services take optional dependencies (`VoidweaverPlayer`, `ScrobbleQueue`, `AudioCache`) so tests can inject fakes.

## Conventions

- Use `debugPrint()` for logging.
- Every service and `State` that owns subscriptions, timers, controllers or HTTP clients disposes them in `dispose()`. `test/services/memory_leak_test.dart` covers the services.
- Check `mounted` after `await` in widgets.
- Screens choose layouts with `MediaQuery.of(context).orientation`, using `_buildPortraitLayout()` / `_buildLandscapeLayout()`. Test both orientations when changing a screen.
- Wrap independent screen sections in `.withErrorBoundary()`.
- The analyzer runs with `strict-casts`, `strict-raw-types`, `discarded_futures` and `unawaited_futures`. Cast JSON values explicitly (`json['id'] as String?`), and mark fire-and-forget futures with `unawaited(...)`, adding `.catchError` when a failure needs more than the zone's error report.
- Let exceptions keep their type (rethrow rather than wrapping them in `Exception('...: $e')`) and show them with `NetworkErrorHelper.getErrorMessage(e, context: '...')`, never with `toString()`. Throw `UserFacingException` for errors whose message is meant for the user.
- `AudioPlayerService` doesn't notify its listeners for position updates (several a second). Widgets that show the position listen to `AudioPlayerService.position`.

## Playback internals

How the player's queue is followed, downloads swapped in, load errors, skips, system controls and audio focus are described in [PLAYBACK.md](PLAYBACK.md). Read it before changing `audio_player_service.dart` or the plugin.

## Android

- `MainActivity` keeps its `FlutterEngine` cached so Dart keeps running without the activity (see [PLAYBACK.md](PLAYBACK.md#bluetooth-and-system-controls)). It must not request audio focus (see [PLAYBACK.md](PLAYBACK.md#audio-focus)).
- The plugin's manifest declares `PlaybackService` (`foregroundServiceType="mediaPlayback"`) and its permissions; it's merged into the app's.
- Versioning: the version name (`1.1.0`) comes from `pubspec.yaml` and is bumped by hand. The build number (`versionCode`) is the git commit count, set in `android/app/build.gradle.kts`, so it rises with every commit; the pubspec's `+N` or `--build-number` only wins if it's higher. CI checks out the full history for this. Settings shows both at the bottom.

## Tests

See [test/README.md](../test/README.md).
