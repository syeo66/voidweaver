// User flows of the whole app on a device, against a fake Subsonic server
// running inside the app (test/test_helpers/fake_subsonic_server.dart). The
// player is the real one (Media3 ExoPlayer, media session), streaming from
// that server, which debug builds trust for localhost.
//
//   flutter test integration_test -d <device>
//
// Needs an Android device or emulator; the host test runner can't run them.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/main.dart';
import 'package:voidweaver/screens/home_screen.dart';
import 'package:voidweaver/services/app_state.dart';
import 'package:voidweaver/services/audio_cache.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/utils/log.dart';
import 'package:voidweaver/utils/validators.dart';

import '../test/test_helpers/fake_subsonic_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late FakeSubsonicServer server;

  setUpAll(() {
    setUpLogging();
    // The app's own HTTP requests (API, cover art) trust the fake server
    HttpOverrides.global = FakeSubsonicServer.httpOverrides;
  });

  setUp(() async {
    // A fresh install: logged out, nothing saved
    await const FlutterSecureStorage().deleteAll();
    await (await SharedPreferences.getInstance()).clear();
    server = FakeSubsonicServer();
    await server.start();
  });

  tearDown(() async => server.close());

  /// Starts the app and logs in through the login screen
  Future<AppState> startAndLogIn(WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    // Released at the end, which ends the media session
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await _pumpUntil(
      tester,
      () => find.text('Connect').evaluate().isNotEmpty,
      'login',
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Server URL (HTTPS required)'),
      server.url,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Username'),
      server.username,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      server.password,
    );
    await tester.tap(find.text('Connect'));
    await _pumpUntil(
      tester,
      () => find.text('First Light').evaluate().isNotEmpty,
      'the album list',
    );
    return tester.element(find.byType(HomeScreen)).read<AppState>();
  }

  AudioPlayerService playerOf(AppState appState) =>
      appState.audioPlayerService!;

  /// Closes the app and starts it again with what it saved (the login, the
  /// queue and its position): the widget tree is removed, which releases the
  /// services and the media session, and a new app is started on the same
  /// storage. Returns once it shows the album list again.
  ///
  /// Still the same process, which a widget test can't leave: Dart statics
  /// survive, e.g. SharedPreferences' copy of its values in memory, so the
  /// saved queue comes back from that copy, not from disk. The position's
  /// file (`playback_position.json`) is read from disk.
  Future<AppState> restart(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MyApp());
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await _pumpUntil(
      tester,
      () => find.text('First Light').evaluate().isNotEmpty,
      'the album list after the restart',
    );
    return tester.element(find.byType(HomeScreen)).read<AppState>();
  }

  testWidgets('plays an album to its end and scrobbles each track', (
    tester,
  ) async {
    final appState = await startAndLogIn(tester);
    final player = playerOf(appState);

    await tester.tap(find.text('First Light'));
    await _pumpUntil(
      tester,
      () => player.playbackState == PlaybackState.playing,
      'playback to start',
    );
    expect(player.playlist.map((s) => s.title), ['Dawn', 'Noon', 'Dusk']);
    expect(player.currentIndex, 0);

    // The player moves on by itself, four seconds per track
    await _pumpUntil(tester, () => player.currentIndex == 1, 'the 2nd track');
    await _pumpUntil(tester, () => player.currentIndex == 2, 'the 3rd track');

    // At the end it stops on the last track, paused at its start
    await _pumpUntil(
      tester,
      () =>
          player.playbackState == PlaybackState.paused &&
          player.currentPosition == Duration.zero,
      'the end of the album',
    );
    expect(player.currentIndex, 2);

    List<String> plays() => [
      for (final s in server.scrobbles)
        if (s.submission) s.songId,
    ];
    await _pumpUntil(tester, () => plays().length == 3, 'three plays');
    expect(plays(), ['s-1', 's-2', 's-3']);
    // Each track was announced as playing once
    expect(
      server.scrobbles.where((s) => !s.submission).map((s) => s.songId),
      containsAllInOrder(['s-1', 's-2', 's-3']),
    );
  });

  testWidgets('plays random songs and pauses from the player controls', (
    tester,
  ) async {
    final appState = await startAndLogIn(tester);
    final player = playerOf(appState);

    await tester.tap(find.byTooltip('Play random songs'));
    await _pumpUntil(
      tester,
      () => player.playbackState == PlaybackState.playing,
      'playback to start',
    );
    // All songs the server has, fewer than asked for
    expect(player.playlist, hasLength(7));
    expect(server.requestsTo('getRandomSongs').single.params['size'], '50');

    await tester.tap(find.byTooltip('Pause'));
    await _pumpUntil(
      tester,
      () => player.playbackState == PlaybackState.paused,
      'the pause',
    );
    // The position may still settle by a few hundred ms after the pause is
    // reported (on slow CI emulators ExoPlayer's playback thread catches up
    // later), but it doesn't keep advancing.
    final position = player.currentPosition;
    await tester.pump(const Duration(seconds: 2));
    expect(
      player.currentPosition - position,
      lessThan(const Duration(milliseconds: 500)),
    );

    await tester.tap(find.byTooltip('Play'));
    await _pumpUntil(
      tester,
      () => player.playbackState == PlaybackState.playing,
      'playback to continue',
    );
  });

  testWidgets('reports a song the server answers with an error at once', (
    tester,
  ) async {
    final appState = await startAndLogIn(tester);
    final player = playerOf(appState);

    // A Subsonic error for every stream (HTTP 200 with an XML body), like an
    // unknown song or a password changed on the server
    server.failingEndpoints.add('stream');
    await tester.tap(find.text('First Light'));
    // Well under the 25 s the player retries a network error for
    await _pumpUntil(
      tester,
      () => find.textContaining('Failed to play album').evaluate().isNotEmpty,
      'the error',
      timeout: const Duration(seconds: 10),
    );
    expect(player.playbackState, PlaybackState.stopped);
    expect(player.currentSong?.title, 'Dawn');
    // Asked once: the server would give the same answer again
    expect(server.requestsTo('stream').map((r) => r.params['id']), ['s-1']);
  });

  testWidgets('asks for the new password after it changed on the server', (
    tester,
  ) async {
    final appState = await startAndLogIn(tester);
    expect(find.text('Update password'), findsNothing);

    server.password = 'changed on the server';
    await appState.loadAlbums(forceRefresh: true);
    await _pumpUntil(
      tester,
      () => find.text('Update password').evaluate().isNotEmpty,
      'the banner',
    );

    await tester.tap(find.text('Update password'));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextFormField),
    );
    await tester.enterText(field, 'a wrong one');
    await tester.tap(find.text('Update'));
    await _pumpUntil(
      tester,
      () => find.text('Wrong username or password.').evaluate().isNotEmpty,
      'the error',
    );

    await tester.enterText(field, 'changed on the server');
    await tester.tap(find.text('Update'));
    await _pumpUntil(
      tester,
      () => find.byType(AlertDialog).evaluate().isEmpty,
      'the dialog to close',
    );
    await _pumpUntil(
      tester,
      () => find.text('Update password').evaluate().isEmpty,
      'the banner to go',
    );
    expect(appState.isConfigured, isTrue);

    // Streams with the new password
    final player = playerOf(appState);
    await tester.tap(find.text('Second Wind'));
    await _pumpUntil(
      tester,
      () => player.playbackState == PlaybackState.playing,
      'playback to start',
    );
    expect(player.currentSong?.title, 'Gust');
  });

  testWidgets('restores the queue and the position after a restart', (
    tester,
  ) async {
    final before = await startAndLogIn(tester);
    final player = playerOf(before);

    await tester.tap(find.text('First Light'));
    await _pumpUntil(tester, () => player.currentIndex == 1, 'the 2nd track');
    // Well into the track, which is four seconds long, so the position isn't
    // a start that any restore would give
    await _pumpUntil(
      tester,
      () => player.currentPosition >= const Duration(milliseconds: 1500),
      'the middle of the 2nd track',
    );
    await tester.tap(find.byTooltip('Pause'));
    await _pumpUntil(
      tester,
      () => player.playbackState == PlaybackState.paused,
      'the pause',
    );
    // The position settles by a few hundred ms after the pause is reported
    await tester.pump(const Duration(seconds: 1));
    final position = player.currentPosition;
    expect(position, greaterThan(const Duration(seconds: 1)));
    expect(player.currentIndex, 1);

    final after = await restart(tester);
    expect(after, isNot(same(before)));
    final restored = playerOf(after);
    await _pumpUntil(
      tester,
      () => restored.playlist.isNotEmpty,
      'the queue to come back',
    );
    expect(restored.playlist.map((s) => s.title), ['Dawn', 'Noon', 'Dusk']);
    expect(restored.currentIndex, 1);
    // Waits for the restored track to load, which is when it's paused
    await _pumpUntil(
      tester,
      () => restored.playbackState == PlaybackState.paused,
      'the restored track to be ready',
    );
    expect(
      (restored.currentPosition - position).abs(),
      lessThan(const Duration(milliseconds: 750)),
    );

    // Not playing by itself; Play goes on from there
    await tester.pump(const Duration(seconds: 1));
    expect(restored.playbackState, PlaybackState.paused);
    final resumedFrom = restored.currentPosition;
    await tester.tap(find.byTooltip('Play'));
    await _pumpUntil(
      tester,
      () =>
          restored.playbackState == PlaybackState.playing &&
          restored.currentPosition > resumedFrom,
      'playback to go on',
    );
    expect(restored.currentIndex, 1);
  });

  testWidgets('plays on through the cached tracks when the server is gone', (
    tester,
  ) async {
    final appState = await startAndLogIn(tester);
    final player = playerOf(appState);
    // Only what this test downloads
    await player.clearAudioCache();
    final errors = <String>[];
    final errorSubscription = player.playbackErrors.listen(errors.add);
    addTearDown(errorSubscription.cancel);

    await tester.tap(find.text('First Light'));
    await _pumpUntil(
      tester,
      () => player.playbackState == PlaybackState.playing,
      'playback to start',
    );
    // Paused on the first track, the two after it get cached: downloaded
    // ahead, and read ahead by the player, which buffers the next tracks
    // (they're short here) through the cache either way
    await tester.tap(find.byTooltip('Pause'));
    await _pumpUntil(
      tester,
      () => player.playbackState == PlaybackState.paused,
      'the pause',
    );
    final audio = AudioCache(
      namespace: Validators.normalizeServerUrl(server.url),
    );
    final upcoming = player.playlist.sublist(1);
    expect(upcoming.map((s) => s.title), ['Noon', 'Dusk']);
    await _pumpUntilAsync(tester, () async {
      for (final song in upcoming) {
        if (await audio.firstCached([song]) == null) return false;
      }
      return true;
    }, 'the next two tracks to be cached');

    // The server is gone: nothing can be streamed from here on
    final port = server.port;
    await server.close();
    await expectLater(
      Socket.connect(InternetAddress.loopbackIPv4, port),
      throwsA(isA<SocketException>()),
    );

    await tester.tap(find.byTooltip('Next'));
    await _pumpUntil(tester, () => player.currentIndex == 1, 'the 2nd track');
    await tester.tap(find.byTooltip('Play'));
    await _pumpUntil(tester, () => player.currentIndex == 2, 'the 3rd track');
    // The last track plays to its end: paused at its start, as after any album
    await _pumpUntil(
      tester,
      () =>
          player.playbackState == PlaybackState.paused &&
          player.currentPosition == Duration.zero,
      'the end of the album',
    );
    expect(player.currentIndex, 2);
    expect(errors, isEmpty);
  });

  testWidgets('lands on the last track asked for when skipping during a load', (
    tester,
  ) async {
    final appState = await startAndLogIn(tester);
    final player = playerOf(appState);
    final errors = <String>[];
    final errorSubscription = player.playbackErrors.listen(errors.add);
    addTearDown(errorSubscription.cancel);

    // Every stream waits, so the album is still loading when the buttons are
    // pressed
    server.streamDelay = const Duration(seconds: 2);
    await tester.tap(find.text('First Light'));
    await _pumpUntil(
      tester,
      () => find.byTooltip('Next').evaluate().isNotEmpty,
      'the player controls',
    );
    expect(player.playbackState, PlaybackState.loading);
    // Twice, a moment apart: the second press moves the first one's target
    await tester.tap(find.byTooltip('Next'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('Next'));

    // The first track that plays is the last one asked for, not one of the
    // tracks on the way
    await _pumpUntil(
      tester,
      () => player.playbackState == PlaybackState.playing,
      'playback to start',
    );
    expect(player.currentIndex, 2);
    expect(player.currentSong?.title, 'Dusk');
    await _pumpUntil(
      tester,
      () =>
          player.playbackState == PlaybackState.paused &&
          player.currentPosition == Duration.zero,
      'the end of the album',
    );
    expect(player.currentIndex, 2);

    // The play is sent after the album has ended, so it may still be on its way
    await _pumpUntil(
      tester,
      () => server.scrobbles.any((s) => s.songId == 's-3' && s.submission),
      'the play of Dusk',
    );
    // Only the track that played is reported: not the ones skipped over
    expect(
      [for (final s in server.scrobbles) (s.songId, s.submission)],
      [('s-3', false), ('s-3', true)],
    );
    expect(errors, isEmpty);
  });
}

/// Pumps frames until [condition] holds, failing after [timeout]
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition,
  String what, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      final texts = [
        for (final e in find.byType(Text).evaluate()) (e.widget as Text).data,
      ];
      fail('Timed out waiting for $what. On screen: $texts');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Like [_pumpUntil] for a [condition] that has to wait for something
Future<void> _pumpUntilAsync(
  WidgetTester tester,
  Future<bool> Function() condition,
  String what, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $what');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}
