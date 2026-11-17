import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/main.dart';
import 'package:voidweaver/screens/login_screen.dart';
import 'package:voidweaver/services/app_state.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/launcher_shortcuts.dart';
import 'package:voidweaver/services/network_errors.dart';
import 'package:voidweaver/services/replaygain_reader.dart';
import 'package:voidweaver/services/settings_service.dart';
import 'package:voidweaver/services/subsonic_api.dart';

import '../test_helpers/fake_audio_cache.dart';
import '../test_helpers/mock_api.dart';
import '../test_helpers/mock_audio_player.dart';
import '../test_helpers/mocks.mocks.dart';
import '../test_helpers/waiting.dart';

/// Logged in with [player] (logged out without one), without a server.
/// Initialized once [initialized] completes.
class _FakeAppState extends AppState {
  final SubsonicApi? _fakeApi;
  final AudioPlayerService? _fakePlayer;
  final Future<void>? initialized;

  _FakeAppState(this._fakeApi, this._fakePlayer, {this.initialized});

  @override
  Future<void> initialize() => initialized ?? Future<void>.value();

  @override
  SubsonicApi? get api => _fakeApi;

  @override
  AudioPlayerService? get audioPlayerService => _fakePlayer;

  @override
  bool get isConfigured => _fakePlayer != null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('voidweaver/shortcuts');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // Like MainActivity: a tap sets it, a take reads and clears it
  late bool tapped;
  late int takes;

  late MockSubsonicApi mockApi;
  late SettingsService settings;
  late AudioPlayerService service;

  Song song(String id) => Song(
    id: id,
    title: 'Title $id',
    artist: 'Artist $id',
    album: 'Album $id',
    duration: 180,
    replayGainTrackGain: -6.0,
  );

  setUp(() async {
    tapped = false;
    takes = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'takeRandomRequest');
      takes++;
      final wasTapped = tapped;
      tapped = false;
      return wasTapped;
    });

    SharedPreferences.setMockInitialValues({});
    mockApi = newMockApi();
    when(mockApi.getArtists()).thenAnswer((_) async => []);
    when(mockApi.getRandomSongs(any))
        .thenAnswer((_) async => [song('r1'), song('r2')]);
    when(mockApi.getStreamUrl(any)).thenAnswer(
      (invocation) =>
          'https://music.test/rest/stream?id=${invocation.positionalArguments.first}',
    );
    when(mockApi.readReplayGain(any))
        .thenAnswer((_) async => const ReplayGainData());

    settings = SettingsService();
    await settings.initialize();
    // Reachable: an unreachable cache would retry its downloads on a timer
    // that outlasts the test's fake clock
    service = AudioPlayerService(
      mockApi,
      settings,
      audioPlayer: MockAudioPlayer(),
      audioCache: FakeAudioCache(),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    service.dispose();
  });

  group('LauncherShortcuts', () {
    test('answers a tap once', () async {
      tapped = true;
      expect(await LauncherShortcuts.takeRandomRequest(), isTrue);
      expect(await LauncherShortcuts.takeRandomRequest(), isFalse);
    });

    test('answers false without a handler', () async {
      // No activity has attached to the engine, or not on Android
      messenger.setMockMethodCallHandler(channel, null);
      expect(await LauncherShortcuts.takeRandomRequest(), isFalse);
    });
  });

  group('AppRouter', () {
    Future<void> pumpApp(WidgetTester tester, AppState appState) async {
      addTearDown(appState.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: appState,
          child: const MaterialApp(home: AppRouter()),
        ),
      );
      await tester.pump();
    }

    Future<void> randomPlaying(WidgetTester tester) => pumpFramesUntil(
      tester,
      () => service.playlist.isNotEmpty,
      reason: 'random songs to play',
    );

    // Nothing shows that a pull found no tap; a take is the last thing
    // before a start, so after the takes the start would have begun
    Future<void> taken(WidgetTester tester, int count) =>
        pumpFramesUntil(tester, () => takes >= count, reason: '$count takes');

    // To the background and back, one valid transition at a time
    void bringToFront(WidgetTester tester) {
      for (final state in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    testWidgets('plays random songs for a tap that started the app', (
      tester,
    ) async {
      tapped = true;
      await pumpApp(tester, _FakeAppState(mockApi, service));

      await randomPlaying(tester);
      expect(service.playlist.map((s) => s.id), ['r1', 'r2']);
      verify(mockApi.getRandomSongs(any)).called(1);
    });

    testWidgets('plays random songs for a tap while it runs', (tester) async {
      await pumpApp(tester, _FakeAppState(mockApi, service));
      await taken(tester, 1);
      expect(service.playlist, isEmpty);

      tapped = true;
      bringToFront(tester);

      await randomPlaying(tester);
      verify(mockApi.getRandomSongs(any)).called(1);
    });

    testWidgets('does nothing when it comes to the front without a tap', (
      tester,
    ) async {
      await pumpApp(tester, _FakeAppState(mockApi, service));
      await taken(tester, 1);

      bringToFront(tester);
      await taken(tester, 2);
      await tester.pump();

      verifyNever(mockApi.getRandomSongs(any));
    });

    testWidgets('starts once for a tap asked about twice', (tester) async {
      tapped = true;
      await pumpApp(tester, _FakeAppState(mockApi, service));
      // Comes to the front right after the start
      bringToFront(tester);

      await randomPlaying(tester);
      await taken(tester, 2);
      await tester.pump();
      verify(mockApi.getRandomSongs(any)).called(1);
    });

    testWidgets('asks only once it is initialized', (tester) async {
      final initialized = Completer<void>();
      tapped = true;
      await pumpApp(
        tester,
        _FakeAppState(mockApi, service, initialized: initialized.future),
      );

      bringToFront(tester);
      await tester.pump();
      expect(takes, 0);

      initialized.complete();
      await randomPlaying(tester);
      expect(takes, 1);
    });

    testWidgets('drops a tap while logged out', (tester) async {
      tapped = true;
      await pumpApp(tester, _FakeAppState(null, null));
      await taken(tester, 1);

      expect(find.byType(LoginScreen), findsOneWidget);
      // Taken, not kept for after a login
      expect(tapped, isFalse);
    });

    testWidgets('shows why random songs could not be played', (tester) async {
      when(mockApi.getRandomSongs(any)).thenAnswer(
        (_) async => throw const UserFacingException('Server is down'),
      );
      tapped = true;
      await pumpApp(tester, _FakeAppState(mockApi, service));

      await pumpFramesUntil(
        tester,
        () => find
            .text('Failed to play random songs: Server is down')
            .evaluate()
            .isNotEmpty,
        reason: 'the error to show',
      );
      expect(service.playlist, isEmpty);
    });
  });
}
