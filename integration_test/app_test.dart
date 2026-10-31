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
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/utils/log.dart';

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
        tester, () => find.text('Connect').evaluate().isNotEmpty, 'login');

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Server URL (HTTPS required)'),
        server.url);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'), server.username);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'), server.password);
    await tester.tap(find.text('Connect'));
    await _pumpUntil(tester,
        () => find.text('First Light').evaluate().isNotEmpty, 'the album list');
    return tester.element(find.byType(HomeScreen)).read<AppState>();
  }

  AudioPlayerService playerOf(AppState appState) =>
      appState.audioPlayerService!;

  testWidgets('plays an album to its end and scrobbles each track',
      (tester) async {
    final appState = await startAndLogIn(tester);
    final player = playerOf(appState);

    await tester.tap(find.text('First Light'));
    await _pumpUntil(
        tester,
        () => player.playbackState == PlaybackState.playing,
        'playback to start');
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
        'the end of the album');
    expect(player.currentIndex, 2);

    List<String> plays() => [
          for (final s in server.scrobbles)
            if (s.submission) s.songId
        ];
    await _pumpUntil(tester, () => plays().length == 3, 'three plays');
    expect(plays(), ['s-1', 's-2', 's-3']);
    // Each track was announced as playing once
    expect(server.scrobbles.where((s) => !s.submission).map((s) => s.songId),
        containsAllInOrder(['s-1', 's-2', 's-3']));
  });

  testWidgets('plays random songs and pauses from the player controls',
      (tester) async {
    final appState = await startAndLogIn(tester);
    final player = playerOf(appState);

    await tester.tap(find.byTooltip('Play random songs'));
    await _pumpUntil(
        tester,
        () => player.playbackState == PlaybackState.playing,
        'playback to start');
    // All songs the server has, fewer than asked for
    expect(player.playlist, hasLength(7));
    expect(server.requestsTo('getRandomSongs').single.params['size'], '50');

    await tester.tap(find.byTooltip('Pause'));
    await _pumpUntil(tester, () => player.playbackState == PlaybackState.paused,
        'the pause');
    final position = player.currentPosition;
    await tester.pump(const Duration(seconds: 1));
    expect(player.currentPosition, position);

    await tester.tap(find.byTooltip('Play'));
    await _pumpUntil(
        tester,
        () => player.playbackState == PlaybackState.playing,
        'playback to continue');
  });

  testWidgets('asks for the new password after it changed on the server',
      (tester) async {
    final appState = await startAndLogIn(tester);
    expect(find.text('Update password'), findsNothing);

    server.password = 'changed on the server';
    await appState.loadAlbums(forceRefresh: true);
    await _pumpUntil(tester,
        () => find.text('Update password').evaluate().isNotEmpty, 'the banner');

    await tester.tap(find.text('Update password'));
    await tester.pumpAndSettle();
    final field = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextFormField));
    await tester.enterText(field, 'a wrong one');
    await tester.tap(find.text('Update'));
    await _pumpUntil(
        tester,
        () => find.text('Wrong username or password.').evaluate().isNotEmpty,
        'the error');

    await tester.enterText(field, 'changed on the server');
    await tester.tap(find.text('Update'));
    await _pumpUntil(tester, () => find.byType(AlertDialog).evaluate().isEmpty,
        'the dialog to close');
    await _pumpUntil(
        tester,
        () => find.text('Update password').evaluate().isEmpty,
        'the banner to go');
    expect(appState.isConfigured, isTrue);

    // Streams with the new password
    final player = playerOf(appState);
    await tester.tap(find.text('Second Wind'));
    await _pumpUntil(
        tester,
        () => player.playbackState == PlaybackState.playing,
        'playback to start');
    expect(player.currentSong?.title, 'Gust');
  });
}

/// Pumps frames until [condition] holds, failing after [timeout]
Future<void> _pumpUntil(
    WidgetTester tester, bool Function() condition, String what,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      final texts = [
        for (final e in find.byType(Text).evaluate()) (e.widget as Text).data
      ];
      fail('Timed out waiting for $what. On screen: $texts');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}
