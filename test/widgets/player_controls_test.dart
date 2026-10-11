import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/audio_cache.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/settings_service.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:voidweaver/widgets/player_controls.dart';

import '../test_helpers/mock_audio_player.dart';
import 'player_controls_test.mocks.dart';

@GenerateMocks([SubsonicApi, SettingsService])
void main() {
  late MockSubsonicApi mockApi;
  late MockSettingsService mockSettings;
  late MockAudioPlayer player;
  late AudioCache cache;
  late AudioPlayerService service;

  Song song(String id) => Song(
        id: id,
        title: 'Title $id',
        artist: 'Artist $id',
        album: 'Album',
        duration: 180,
        replayGainTrackGain: -6.0,
      );

  final album = Album(
    id: 'album1',
    name: 'Album',
    artist: 'Artist',
    songs: [song('s1'), song('s2')],
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockSubsonicApi();
    mockSettings = MockSettingsService();
    player = MockAudioPlayer();

    when(mockSettings.replayGainMode).thenReturn(ReplayGainMode.off);
    when(mockSettings.replayGainPreamp).thenReturn(0.0);
    when(mockSettings.replayGainFallbackGain).thenReturn(0.0);
    when(mockSettings.replayGainPreventClipping).thenReturn(true);
    when(mockSettings.scrobbleMinPlayTimeMinutes).thenReturn(4.0);
    when(mockSettings.scrobbleThresholdPercent).thenReturn(50.0);
    when(mockSettings.calculateVolumeAdjustment(
      trackGain: anyNamed('trackGain'),
      albumGain: anyNamed('albumGain'),
      trackPeak: anyNamed('trackPeak'),
      albumPeak: anyNamed('albumPeak'),
    )).thenReturn(1.0);
    when(mockApi.getStreamUrl(any)).thenAnswer((invocation) =>
        'https://music.test/rest/stream?id=${invocation.positionalArguments.first}');

    // No disk cache in widget tests: preloading is a no-op
    cache = AudioCache(
      client: MockClient((_) async => http.Response('offline', 503)),
      directoryProvider: () async => throw UnsupportedError('no disk'),
    );
    service = AudioPlayerService(mockApi, mockSettings,
        audioPlayer: player, audioCache: cache);
  });

  tearDown(() {
    service.dispose();
    cache.dispose();
  });

  Future<void> pumpControls(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider<AudioPlayerService>.value(
            value: service,
            child: const Align(
              alignment: Alignment.bottomCenter,
              child: PlayerControls(),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> playAlbum(WidgetTester tester) async {
    await tester.runAsync(() => service.playAlbum(album));
    await tester.pump();
  }

  IconButton buttonWithIcon(WidgetTester tester, IconData icon) =>
      tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));

  testWidgets('renders nothing without a current song', (tester) async {
    await pumpControls(tester);

    expect(find.byType(Slider), findsNothing);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
  });

  testWidgets('shows the current song and its duration', (tester) async {
    await pumpControls(tester);
    await playAlbum(tester);

    expect(find.text('Title s1'), findsOneWidget);
    expect(find.text('Artist s1'), findsOneWidget);
    expect(find.text('0:00'), findsOneWidget);
    expect(find.text('3:00'), findsOneWidget);
  });

  testWidgets('toggles between pause and play', (tester) async {
    await pumpControls(tester);
    await playAlbum(tester);

    expect(find.byIcon(Icons.pause), findsOneWidget);

    await tester.tap(find.byIcon(Icons.pause));
    await tester.pump();

    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(service.playbackState, PlaybackState.paused);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();

    expect(find.byIcon(Icons.pause), findsOneWidget);
  });

  testWidgets('enables skip buttons according to the playlist position',
      (tester) async {
    await pumpControls(tester);
    await playAlbum(tester);

    expect(buttonWithIcon(tester, Icons.skip_previous).onPressed, isNull);
    expect(buttonWithIcon(tester, Icons.skip_next).onPressed, isNotNull);
  });

  testWidgets('skip next shows the following song', (tester) async {
    await pumpControls(tester);
    await playAlbum(tester);

    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.skip_next));
      // Let the skip finish loading the next track
      await Future.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(find.text('Title s2'), findsOneWidget);
    expect(buttonWithIcon(tester, Icons.skip_previous).onPressed, isNotNull);
    expect(buttonWithIcon(tester, Icons.skip_next).onPressed, isNull);
  });

  testWidgets('moving the slider seeks', (tester) async {
    await pumpControls(tester);
    await playAlbum(tester);

    await tester.tap(find.byType(Slider));
    await tester.pump();

    // A tap in the middle of the slider seeks to the middle of the song
    expect(player.position.inSeconds, closeTo(90, 2));
  });

  testWidgets('shows the sleep timer while it runs', (tester) async {
    await pumpControls(tester);
    await playAlbum(tester);

    expect(find.byIcon(Icons.bedtime), findsNothing);

    service.startSleepTimer(const Duration(minutes: 30));
    await tester.pump();

    expect(find.byIcon(Icons.bedtime), findsOneWidget);
    // Remaining time comes from the wall clock, so it may already be 29:59
    expect(find.textContaining(RegExp(r'Sleep timer: (30:00|29:59)')),
        findsOneWidget);

    service.cancelSleepTimer();
    await tester.pump();

    expect(find.byIcon(Icons.bedtime), findsNothing);
  });
}
