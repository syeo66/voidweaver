# Tests

```bash
flutter test                                   # everything
flutter test test/services/scrobble_queue_test.dart
flutter test --coverage
```

Tests need no device, network or platform plugins.

## Randomized playback test

`services/playback_random_actions_test.dart` runs random sequences of presses (in the app and as system commands) and player events (track ends, buffering, load errors, failing URLs, slow seeks and loads, audio focus loss) against `AudioPlayerService` with the fake player, and checks rules that must hold once everything has settled: no skip or start left in progress, nothing stuck at loading, the player holding the service's playlist and on its track, the state matching the player, Pause/Stop and Play holding, an unsuperseded failure stopped and reported once, "now playing" only for the player's current item, no more scrobbles than plays, errors only for tracks the player has been on. 400 runs by default (about 2 s); each rule about the last press checks a good share of them, so a change to the model can't switch one off unnoticed.

```bash
flutter test test/services/playback_random_actions_test.dart --dart-define=PLAYBACK_SEED=<seed>  # replay one, with the service's log
flutter test test/services/playback_random_actions_test.dart --dart-define=PLAYBACK_RUNS=20000   # more runs; prints how often each rule was checked
flutter test test/services/playback_random_actions_test.dart --dart-define=PLAYBACK_STEPS=120    # longer runs (default 40 steps)
```

Run it with many more runs after changing `audio_player_service.dart`. When it fails, check first whether the fake player can do what the run shows: most false alarms so far were the fake doing something the real one can't (see `mock_audio_player.dart`, whose behaviors follow `PlaylistPlayer` and Media3). A real bug gets a readable regression test of its own in the matching test file.

It doesn't use `fakeAsync`: awaiting `StreamSubscription.cancel()` on a broadcast stream continues on the root zone's microtask queue, which `fakeAsync` doesn't run, so `_seekToItem()` never returns there. Keep that in mind for any `fakeAsync` test of the player service. Time is a fake clock passed to the service instead, and the event loop only advances through `pumpEventQueue()`, so a seed always replays the same way.

## Integration tests

`integration_test/` runs user flows of the whole app on a device or emulator: log in, play an album to its end (scrobbles included), random songs and the player controls, and a password changed on the server. They run against `FakeSubsonicServer`, which runs inside the app, with the real player (Media3 ExoPlayer and its media session) streaming from it.

```bash
flutter test integration_test -d emulator-5554   # or: make test-integration
```

Each test starts from a fresh install (credentials and SharedPreferences cleared). CI runs them in an emulator. They use a debug build, so they don't replace `tool/emulator_check.sh` (release build, R8, media keys, resumption), which runs locally only, not in CI (see below and [docs/ANDROID.md](../docs/ANDROID.md)).

## Fake Subsonic server

`test_helpers/fake_subsonic_server.dart` is a Subsonic server over HTTPS on localhost that answers like Navidrome (XML, errors as HTTP 200 with `status="failed"`, token auth): three albums of 4-second WAV tones, random songs, artists, search, scan status, scrobbles (recorded in `scrobbles`), cover art, and range requests for `stream` and `download`. Every request is recorded in `requests`; change `password` to simulate a password changed on the server, and set `downloadsEnabled = false` to refuse `download` like Navidrome with downloads disabled.

Clients have to trust its certificate: set `HttpOverrides.global = FakeSubsonicServer.httpOverrides` (in host tests after `TestWidgetsFlutterBinding.ensureInitialized()`, whose own overrides fail every request). Debug builds of the app trust it for localhost only (`android/app/src/fakeServer/res/xml/network_security_config.xml`), so ExoPlayer can stream from it; the release APK doesn't (`tool/check_release_apk.sh` checks).

`tool/fake_server.dart` runs it on the host with minute-long songs, for `tool/emulator_check.sh --fake-server`. That runs the system checks (media session, media keys, resumption) on a release build that differs from the real one only in trusting the server: `-PtrustFakeServer=true` adds the network security config, and `--dart-define=VOIDWEAVER_TEST_CA=...` makes Dart's HTTP clients trust the CA (`lib/utils/test_ca.dart`). The emulator reaches the server through `adb reverse`. `tool/fake_server_cert.sh` generates the certificate and its CA. The server certificate is valid for 825 days, the most macOS accepts; when the tests fail with a handshake error, run the script again.

Host tests can use it too, for code that has to go through real HTTP (see `services/credentials_rejected_test.dart`).

The player plugin (`packages/voidweaver_player`) has its own tests:

```bash
cd packages/voidweaver_player && flutter test        # Dart API over a mocked method/event channel
cd android && ./gradlew :voidweaver_player:testDebugUnitTest   # Java, on the JVM with Robolectric
```

The Java tests (`packages/voidweaver_player/android/src/test/`) cover `GainAudioProcessor` (gain per item, switched at the item boundary, clipping), `SessionPlayer` (commands forwarded to Dart, the offered commands, idle after an error shown as paused), `MediaCache.ErrorDocumentGuard` and `NetworkMonitor` (one event per validated network). `FakePlayer` stands in for the ExoPlayer. They need `JAVA_HOME` set (see [docs/ANDROID.md](../docs/ANDROID.md#environment)) but no device; they don't replace testing in the emulator.

## Layout

- `services/`: one file per service (API cache, audio cache, scrobble queue, playback restore, ReplayGain parsing and gain calculation, skips, gapless playback and system controls, timeouts, HTTPS enforcement, disposal)
- `utils/`: validators and formatting helpers
- `widgets/`: error boundaries, album list, album tiles (playing on tap, the error shown), player controls, search screen (debounce, stale responses), sync status indicator
- `screens/`: home and settings screens, in portrait and landscape at a phone's size (`tester.view`); artist screens (responses arriving after the screen is gone or the user went back); the advanced network settings dialog (validation, keeping the settings it doesn't show)
- `fixtures/replaygain/`: sample tag data for the parser tests
- `test_helpers/mock_audio_player.dart`: fake `VoidweaverPlayer` holding a sequence, like the real one; `simulateTrackTransition()`, `simulateCompletion()`, `simulateLoadError()`, `simulateBuffering()`/`simulateBufferingEnd()`, `simulateFocusLoss()`, `simulateSystemCommand()`, `failingUrls`, `seekGate`/`loadGate`, `gainOfSource()` etc. It follows the real player where the order of events matters: a `seek()` to another item moves there at once and completes once it's ready (or has failed, after reporting the error); a seek past the end is ignored; an idle player moves on a seek but doesn't load; a new sequence, `stop()` or an error ends a waiting load (`PlayerInterruptedException` or the error) and completes a waiting seek; `play()` keeps the processing state (playWhenReady); a seek takes a completed player back to ready.

## Writing tests

Inject fakes through the optional constructor parameters instead of touching real plugins:

```dart
final service = AudioPlayerService(
  mockApi,
  mockSettings,
  audioPlayer: MockAudioPlayer(),
);
```

- `test_helpers/mocks.dart`: the single `@GenerateMocks([...])` list (`MockSubsonicApi`, `MockSettingsService`). Tests import the generated `test_helpers/mocks.mocks.dart`; add new mocks to that list instead of annotating a test, then run `dart run build_runner build --delete-conflicting-outputs`. Create a `MockSubsonicApi` with `newMockApi()` (`test_helpers/mock_api.dart`), which stubs `hasRejectedCredentials` to false: the player and the scrobble queue ask for it before their own requests, and the mocks are strict.
- `test_helpers/fake_subsonic_server.dart`: see above.
- `test_helpers/fake_audio_cache.dart`: `FakeAudioCache`, an in-memory `AudioCache` (`cached`, `reachable`, `gate`, `downloaded`, `tags`, `simulateNetworkAvailable()`). Pass one to every `AudioPlayerService` that isn't meant to reach the plugin: the real `AudioCache` listens to the plugin's network events. Pass `cache.isCachedKey` to `MockAudioPlayer(isCached: ...)` so cached items play although their URL fails, like with the real cache.
- Scrobble queue and playback restore tests use `SharedPreferences.setMockInitialValues`.
- Dispose services in `tearDown`.
