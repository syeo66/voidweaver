# Development

## Commands

```bash
make setup           # flutter pub get
make run             # run on device/emulator (prefer the Android emulator)
make run-web         # run in Chrome
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

The app is meant to run against Navidrome behind [subsoxy](https://github.com/syeo66/subsoxy), see the [README](../README.md#setup). The app only accepts `https://` URLs (checked in `Validators` and the `SubsonicApi` constructor), so even locally you need a TLS-terminating proxy in front of subsoxy.

Endpoints used: `getAlbumList2`, `getAlbum`, `getArtists`, `getArtist`, `search3`, `getRandomSongs`, `scrobble`, `stream`, `getCoverArt`. subsoxy changes the behavior of `getRandomSongs` and `scrobble`. Everything else passes through to Navidrome.

## Layout

| Path | Purpose |
|------|---------|
| `lib/services/app_state.dart` | App-wide state: login, creates the API and player services, background sync every 5 minutes |
| `lib/services/subsonic_api.dart` | Subsonic client: token auth, response parsing, API cache, HTTP/2 via `http_plus` |
| `lib/services/audio_player_service.dart` | Hands the playlist to `just_audio` and follows it; skips, load errors, ReplayGain volume, scrobbling, prefetching |
| `lib/services/audio_handler.dart` | `audio_service` bridge for lock screen, notification and Bluetooth controls |
| `lib/services/api_cache.dart`, `audio_cache.dart`, `image_cache_manager.dart` | Caching, see [CACHING.md](CACHING.md) |
| `lib/services/scrobble_queue.dart` | Persistent scrobble queue with retries |
| `lib/services/replaygain_reader.dart` | ReplayGain tag parsing, see [REPLAYGAIN.md](REPLAYGAIN.md) |
| `lib/services/playback_persistence.dart` | Saves and restores queue and position |
| `lib/services/network_*.dart` | Timeout presets, retry with backoff, user-facing error messages |
| `lib/services/error_handler.dart`, `lib/widgets/error_boundary.dart` | Global error handler and `ErrorBoundary` / `.withErrorBoundary()` widgets |

State is managed with Provider. Services take optional dependencies (`AudioPlayer`, `ScrobbleQueue`, `AudioCache`) so tests can inject fakes.

## Conventions

- Use `debugPrint()` for logging.
- Every service and `State` that owns subscriptions, timers, controllers or HTTP clients disposes them in `dispose()`. `test/services/memory_leak_test.dart` covers the services.
- Check `mounted` after `await` in widgets.
- Screens choose layouts with `MediaQuery.of(context).orientation`, using `_buildPortraitLayout()` / `_buildLandscapeLayout()`. Test both orientations when changing a screen.
- Wrap independent screen sections in `.withErrorBoundary()`.

## Playback internals

How the player's queue is followed, downloads swapped in, load errors, skips, Bluetooth state masking and audio focus are described in [PLAYBACK.md](PLAYBACK.md). Read it before changing `audio_player_service.dart` or `audio_handler.dart`.

## Android

- `MainActivity` extends `AudioServiceActivity` and creates the `com.voidweaver.audio` notification channel. It must not request audio focus (see [PLAYBACK.md](PLAYBACK.md#audio-focus)).
- `AndroidManifest.xml` declares the `audio_service` `AudioService` (`foregroundServiceType="mediaPlayback"`) and `MediaButtonReceiver`, plus the foreground service, wake lock and Bluetooth permissions.

## Tests

See [test/README.md](../test/README.md).
