# Tests

```bash
flutter test                                   # everything
flutter test test/services/scrobble_queue_test.dart
flutter test --coverage
```

Tests need no device, network or platform plugins.

## Randomized playback test

`services/playback_random_actions_test.dart` runs random sequences of presses (in the app and as system commands) and player events (track ends, buffering, load errors, failing URLs, slow seeks and loads, audio focus loss) against `AudioPlayerService` with the fake player, and checks the rules that must hold once everything has settled. The rules, the seeds and how a run stays deterministic are described at the top of the file. 1000 runs by default (about 4 s).

```bash
flutter test test/services/playback_random_actions_test.dart --dart-define=PLAYBACK_SEED=<seed>      # replay one, with the service's log
flutter test test/services/playback_random_actions_test.dart --dart-define=PLAYBACK_RUNS=20000       # more runs
```

`PLAYBACK_STEPS` and `PLAYBACK_FIRST_SEED` are described in the file too. A failure prints its seed, and `PLAYBACK_STEPS` if it wasn't the default; a replay needs both. A run that takes longer than 30 s fails with its seed and its actions, rather than running into the test's timeout. The nightly workflow runs new seeds every night, see [Nightly checks](#nightly-checks).

Run it with many more runs after changing `audio_player_service.dart`. When it fails, check first whether the fake player can do what the run shows: most false alarms so far were the fake doing something the real one can't (see `mock_audio_player.dart`, whose behaviors follow `PlaylistPlayer` and Media3). A real bug gets a readable regression test of its own in the matching test file.

It doesn't use `fakeAsync`, and neither should a test of the player service: awaiting `StreamSubscription.cancel()` on a broadcast stream continues on the root zone's microtask queue, which `fakeAsync` doesn't run, so `_seekToItem()` never returns there. Time is a fake clock passed to the service, and the event loop only advances through `pumpEventQueue()`.

## Integration tests

`integration_test/` runs user flows of the whole app on a device or emulator: log in, play an album to its end (scrobbles included), random songs and the player controls, a song the server answers with an error (reported at once, not retried), a password changed on the server, the queue and position restored after the app is closed and started again (in the same process, see `restart()`), cached tracks playing on after the server is gone, and skips pressed while the album is still loading (the player lands on the last track asked for, and the songs skipped over aren't scrobbled). They run against `FakeSubsonicServer`, which runs inside the app, with the real player (Media3 ExoPlayer and its media session) streaming from it.

```bash
flutter test integration_test -d emulator-5554   # or: make test-integration
```

Each test starts from a fresh install (credentials and SharedPreferences cleared), so run them on an emulator, not on a phone with the app logged in. Run them after changes to playback, login or the screens they touch. `tool/release.sh` runs them before a release when an emulator is running, and otherwise looks for a nightly run that passed them on the commit (see [docs/RELEASING.md](../docs/RELEASING.md)), and the nightly workflow runs them in CI, see below; the workflow for pushes doesn't. They use a debug build, so they don't replace `tool/emulator_check.sh` (release build, R8, media keys, resumption), which runs nightly in CI too, and before a release (see below and [docs/ANDROID.md](../docs/ANDROID.md)).

## Nightly checks

`.github/workflows/nightly.yml` runs every night (and by hand: `gh workflow run nightly.yml`). It doesn't block pushes or releases.

- The randomized playback test with new seeds: run N of the workflow checks seeds from `N * 100000` on, 25,000 runs of 40 steps, then 10,000 of 120 steps from `N * 100000 + 25000`. The log prints the range; replay a failure locally with the seed (and steps) it prints.
- The integration tests in an emulator in the runner, only if `main` has a commit from the last 25 hours (by its commit date) or the run was started by hand. The emulator sometimes fails to start there (adb can't connect, the system image doesn't unpack), and the test tool sometimes fails to start the Dart Development Service (`--no-dds` doesn't help: the tests then fail to load). So a failed attempt gets a second one in a fresh emulator, and a warning on the run shows that the first one failed, also when the second passes: look at its log for whether a test failed.
- The release-build checks (`tool/emulator_check.sh --fake-server --build`, job `release-build-check`) under the same condition, in an emulator of their own, with a second attempt in the same way. The runner's emulator is x86_64 (Android 15), so the script builds the APK that trusts the fake server for x86_64 there, rather than running the arm64 one through the emulator's slower ARM translation. A failed attempt uploads the script's diagnostics (screenshot, UI hierarchy, logcat) as an artifact of the run.

GitHub emails a failed scheduled run to whoever last changed the workflow's `cron` line, and turns the schedule off after 60 days without activity in the repository.

## Fake Subsonic server

`test_helpers/fake_subsonic_server.dart` is a Subsonic server over HTTPS on localhost that answers like Navidrome (XML, errors as HTTP 200 with `status="failed"`, token auth): three albums of 4-second WAV tones, random songs, artists, search, scan status, scrobbles (recorded in `scrobbles`), cover art, and range requests for `stream` and `download`. Every request is recorded in `requests`; change `password` to simulate a password changed on the server, set `downloadsEnabled = false` to refuse `download` like Navidrome with downloads disabled, and set `streamDelay` to make `stream` wait before it answers (to act on a load that's still pending). `close()` stops it, like a server the app can't reach any more.

Clients have to trust its certificate: set `HttpOverrides.global = FakeSubsonicServer.httpOverrides` (in host tests after `TestWidgetsFlutterBinding.ensureInitialized()`, whose own overrides fail every request). Debug builds of the app trust it for localhost only (`android/app/src/fakeServer/res/xml/network_security_config.xml`), so ExoPlayer can stream from it; the release APK doesn't (`tool/check_release_apk.sh` checks).

`tool/fake_server.dart` runs it on the host with minute-long songs, for `tool/emulator_check.sh --fake-server`. That runs the system checks (media session, media keys, resumption) on a release build that differs from the real one only in trusting the server: `-PtrustFakeServer=true` adds the network security config, and `--dart-define=VOIDWEAVER_TEST_CA=...` makes Dart's HTTP clients trust the CA (`lib/utils/test_ca.dart`). The emulator reaches the server through `adb reverse`. `tool/fake_server_cert.sh` generates the certificate and its CA. The server certificate is valid for 825 days, the most macOS accepts; when the tests fail with a handshake error, run the script again.

Host tests can use it too, for code that has to go through real HTTP (see `services/credentials_rejected_test.dart`).

The player plugin (`packages/voidweaver_player`) has its own tests:

```bash
cd packages/voidweaver_player && flutter test        # Dart API over a mocked method/event channel
cd android && ./gradlew :voidweaver_player:testDebugUnitTest   # Java, on the JVM with Robolectric
```

The Java tests (`packages/voidweaver_player/android/src/test/`) cover `GainAudioProcessor` (gain per item, switched at the item boundary, clipping), `SessionPlayer` (commands forwarded to Dart, the offered commands, idle after an error shown as paused), `MediaCache.ErrorDocumentGuard`, `NetworkMonitor` (one event per validated network) and `PlayerWidget` (what the home screen widget shows for the app's player, the stand-in and without a player, and where its buttons go, on Android 9 and 15 for both ways of picking the layout; Robolectric applies the compact layout, so the larger one is applied by hand). `FakePlayer` stands in for the ExoPlayer. Robolectric gets the plugin's resources (`isIncludeAndroidResources`) and runs the tests against Android 15 (`src/test/resources/robolectric.properties`); left to itself it would pick the target SDK, 36, which it can't set up on this JDK. `PlaylistPlayerTest` is the exception: it drives the real `PlaylistPlayer` and ExoPlayer through the method channel, playing a WAV file from a small HTTP server in the test (the player's data source is HTTP only), and checks the replies the Dart side relies on: a load replies once its start item is ready, or with the error, or with `interrupted` when another load or `stop()` replaces it; a seek replies once its target is ready, or when another seek or `stop()` replaces it. The Dart tests' `MockAudioPlayer` assumes these, so change both together. Robolectric's clock only moves when told to and ExoPlayer's playback thread schedules against it, so a test waits with `tick()`, which advances it; waiting with `Thread.sleep()` alone hangs. They need `JAVA_HOME` set (see [docs/ANDROID.md](../docs/ANDROID.md#environment)) but no device; they don't replace testing in the emulator.

## Layout

`services/`, `models/`, `utils/`, `widgets/` and `screens/` mirror `lib/`: one test file per service, model or screen, named after it. The screen tests run in portrait and landscape at a phone's size (`tester.view`), and `screens/accessibility_test.dart` checks Flutter's tap target, label and contrast guidelines on the home, Now Playing, Settings and login screens in both themes and orientations (Settings is scrolled section by section, as the list builds only what's in view). `fixtures/replaygain/` has sample tag data for the parser tests, and `test_helpers/` the fakes below. `test_helpers/mock_audio_player.dart` is a fake `VoidweaverPlayer` holding a sequence, like the real one (`simulateTrackTransition()`, `simulateCompletion()`, `simulateLoadError()`, `simulateBuffering()`, `simulateFocusLoss()`, `simulateSystemCommand()`, `failingUrls`, `breakAfterLoad`, `seekGate`/`loadGate`, ...; each has a doc comment). It follows the real player where the order of events matters: a `seek()` to another item moves there at once and completes once it's ready (or has failed, after reporting the error); a seek past the end is ignored; an idle player moves on a seek but doesn't load; a new sequence, `stop()` or an error ends a waiting load (`PlayerInterruptedException` or the error) and completes a waiting seek; `play()` keeps the processing state (playWhenReady); a seek takes a completed player back to ready.

## Writing tests

Inject fakes through the optional constructor parameters instead of touching real plugins:

```dart
final service = AudioPlayerService(
  mockApi,
  mockSettings,
  audioPlayer: MockAudioPlayer(),
);
```

- `test_helpers/mocks.dart`: the single `@GenerateMocks([...])` list (`MockSubsonicApi`, `MockSettingsService`). Tests import the generated `test_helpers/mocks.mocks.dart`; add new mocks to that list instead of annotating a test, then run `dart run build_runner build`. Create a `MockSubsonicApi` with `newMockApi()` (`test_helpers/mock_api.dart`), which stubs `hasRejectedCredentials` to false: the player and the scrobble queue ask for it before their own requests, and the mocks are strict.
- `test_helpers/fake_subsonic_server.dart`: see above.
- `test_helpers/fake_audio_cache.dart`: `FakeAudioCache`, an in-memory `AudioCache` (`cached`, `reachable`, `gate`, `downloaded`, `tags`, `simulateNetworkAvailable()`). Pass one to every `AudioPlayerService` that isn't meant to reach the plugin: the real `AudioCache` listens to the plugin's network events. Pass `cache.isCachedKey` to `MockAudioPlayer(isCached: ...)` so cached items play although their URL fails, like with the real cache.
- Scrobble queue and playback restore tests use `SharedPreferences.setMockInitialValues`.
- Dispose services in `tearDown`.

### Waiting

Don't wait a fixed time (`await Future.delayed(...)`) for something to happen: on a slow machine (a CI runner) it's too short and the test fails now and then; on a fast one it wastes time. `test_helpers/waiting.dart` has the alternatives:

- `pumpUntil(condition, reason: ...)`: pumps the event queue, then waits a little real time, until the condition holds; fails after 10 s with the reason. For work that needs real time or I/O. The condition can be async (e.g. reading back a saved position). `pumpFramesUntil(tester, ...)` does the same in a widget test, outside its fake clock and with a frame between checks.
- `pumpEventQueue()` (from `flutter_test`), when only microtasks and zero-length timers are involved: the fake player needs no real time, so a service reacting to its events settles with it, the same way every run.
- Fake time: `testInFakeTime(...)` and `awaitFake(async, future)`, for code that only needs timers, like the scrobble queue (its retries are checked to the millisecond). Not for the player service, see [Randomized playback test](#randomized-playback-test).
- Give `AudioPlayerService` the fake player's clock (`clock: player.clock`) and move it (`player.now = player.now.add(...)`) instead of waiting out the skip debounce.
- The same for expiry and sync timing: `ApiCache.forTesting(clock: ...)`, and `AppState(clock: ...)`, which hands its clock to the API and so to its cache. Move the clock instead of waiting for an entry to expire; `background_sync_test.dart` checks when a sync is due that way.

To check that something did *not* happen, wait for what shows the work is done, then check: `service.pendingPlayerOps == 0`, an injected `ScrobbleQueue` drained (`queueSize == 0`; it sends 100 ms apart), `savesWritten(persistence)` (a read, which waits for the queued file writes, but only when a queue is saved: without one it returns at once), and in a tearDown `allSavesWritten(persistence)` (a clear, which waits for them with or without a queue). Without such a signal a fixed wait is the only way, and it's safe there: one too short can only let the check pass, never fail it. Say so in a comment.
