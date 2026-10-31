# Tests

```bash
flutter test                                   # everything
flutter test test/services/scrobble_queue_test.dart
flutter test --coverage
```

Tests need no device, network or platform plugins.

## Integration tests

`integration_test/` runs user flows of the whole app on a device or emulator: log in, play an album to its end (scrobbles included), random songs and the player controls, and a password changed on the server. They run against `FakeSubsonicServer`, which runs inside the app, with the real player (Media3 ExoPlayer and its media session) streaming from it.

```bash
flutter test integration_test -d emulator-5554   # or: make test-integration
```

Each test starts from a fresh install (credentials and SharedPreferences cleared). CI runs them in an emulator. They use a debug build, so they don't replace `tool/emulator_check.sh` (release build, R8, media keys, resumption); see CLAUDE.md.

## Fake Subsonic server

`test_helpers/fake_subsonic_server.dart` is a Subsonic server over HTTPS on localhost that answers like Navidrome (XML, errors as HTTP 200 with `status="failed"`, token auth): three albums of 4-second WAV tones, random songs, artists, search, scan status, scrobbles (recorded in `scrobbles`), cover art, and range requests for `stream`. Every request is recorded in `requests`; change `password` to simulate a password changed on the server.

Clients have to trust its certificate: set `HttpOverrides.global = FakeSubsonicServer.httpOverrides` (in host tests after `TestWidgetsFlutterBinding.ensureInitialized()`, whose own overrides fail every request). Debug builds of the app trust it for localhost only (`android/app/src/debug/res/xml/network_security_config.xml`), so ExoPlayer can stream from it; release builds don't contain it. `tool/fake_server_cert.sh` generates the certificate and its CA. The server certificate is valid for 825 days, the most macOS accepts; when the tests fail with a handshake error, run the script again.

Host tests can use it too, for code that has to go through real HTTP (see `services/credentials_rejected_test.dart`).

The player plugin (`packages/voidweaver_player`) has its own tests:

```bash
cd packages/voidweaver_player && flutter test        # Dart API over a mocked method/event channel
cd android && ./gradlew :voidweaver_player:testDebugUnitTest   # Java, on the JVM with Robolectric
```

The Java tests (`packages/voidweaver_player/android/src/test/`) cover `GainAudioProcessor` (gain per item, switched at the item boundary, clipping), `SessionPlayer` (commands forwarded to Dart, the offered commands, idle after an error shown as paused) and `MediaCache.ErrorDocumentGuard`. `FakePlayer` stands in for the ExoPlayer. They need `JAVA_HOME` set (see CLAUDE.md) but no device; they don't replace testing in the emulator.

## Layout

- `services/`: one file per service (API cache, audio cache, scrobble queue, playback restore, ReplayGain parsing and gain calculation, skips, gapless playback and system controls, timeouts, HTTPS enforcement, disposal)
- `utils/`: validators and formatting helpers
- `widgets/`: error boundaries, album list, player controls, search screen (debounce, stale responses)
- `screens/`: home and settings screens, in portrait and landscape at a phone's size (`tester.view`); artist screens (responses arriving after the screen is gone or the user went back)
- `fixtures/replaygain/`: sample tag data for the parser tests
- `test_helpers/mock_audio_player.dart`: fake `VoidweaverPlayer` holding a sequence, like the real one; `simulateTrackTransition()`, `simulateCompletion()`, `simulateLoadError()`, `simulateSystemCommand()`, `failingUrls`, `gainOfSource()` etc. Like the real player, a `seek()` to an item in `failingUrls` reports the error, then completes.

## Writing tests

Inject fakes through the optional constructor parameters instead of touching real plugins:

```dart
final service = AudioPlayerService(
  mockApi,
  mockSettings,
  audioPlayer: MockAudioPlayer(),
);
```

- `test_helpers/mocks.dart`: the single `@GenerateMocks([...])` list (`MockSubsonicApi`, `MockSettingsService`). Tests import the generated `test_helpers/mocks.mocks.dart`; add new mocks to that list instead of annotating a test, then run `dart run build_runner build --delete-conflicting-outputs`.
- `test_helpers/fake_subsonic_server.dart`: see above.
- `test_helpers/fake_audio_cache.dart`: `FakeAudioCache`, an in-memory `AudioCache` (`cached`, `reachable`, `gate`, `downloaded`, `tags`). Pass `cache.isCachedKey` to `MockAudioPlayer(isCached: ...)` so cached items play although their URL fails, like with the real cache.
- Scrobble queue and playback restore tests use `SharedPreferences.setMockInitialValues`.
- Dispose services in `tearDown`.
