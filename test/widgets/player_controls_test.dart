import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/settings_service.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:voidweaver/services/replaygain_reader.dart';
import 'package:voidweaver/widgets/player_controls.dart';

import '../test_helpers/fake_audio_cache.dart';
import '../test_helpers/mock_audio_player.dart';
import '../test_helpers/mocks.mocks.dart';

void main() {
  late MockSubsonicApi mockApi;
  late MockSettingsService mockSettings;
  late MockAudioPlayer player;
  late FakeAudioCache cache;
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
      fromAlbum: anyNamed('fromAlbum'),
    )).thenReturn(1.0);
    when(mockApi.getStreamUrl(any)).thenAnswer((invocation) =>
        'https://music.test/rest/stream?id=${invocation.positionalArguments.first}');
    when(mockApi.readReplayGain(any))
        .thenAnswer((_) async => const ReplayGainData());

    // Offline: preloading downloads nothing
    cache = FakeAudioCache()..reachable = false;
    service = AudioPlayerService(mockApi, mockSettings,
        audioPlayer: player, audioCache: cache);
  });

  tearDown(() {
    service.dispose();
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

  testWidgets('pauses and resumes while buffering', (tester) async {
    await pumpControls(tester);
    await playAlbum(tester);

    await tester.runAsync(() async {
      player.simulateBuffering();
      await pumpEventQueue();
    });
    await tester.pump();

    expect(find.bySemanticsLabel('Loading'), findsOneWidget);
    await tester.runAsync(() => tester.tap(find.byIcon(Icons.pause)));
    await tester.pump();

    expect(player.playing, isFalse);
    expect(find.bySemanticsLabel('Loading'), findsOneWidget);
    await tester.runAsync(() => tester.tap(find.byIcon(Icons.play_arrow)));
    await tester.pump();

    expect(player.playing, isTrue);
  });

  testWidgets('enables skip buttons according to the playlist position',
      (tester) async {
    await pumpControls(tester);
    await playAlbum(tester);

    // Previous restarts the first track
    expect(buttonWithIcon(tester, Icons.skip_previous).onPressed, isNotNull);
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

  testWidgets('follows the position without notifying the service',
      (tester) async {
    await pumpControls(tester);
    await playAlbum(tester);
    var notifications = 0;
    service.addListener(() => notifications++);

    // The service subscribed outside the fake clock (in setUp)
    await tester.runAsync(() async {
      player.simulatePositionChange(const Duration(seconds: 30));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();

    expect(find.text('0:30'), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).value,
        closeTo(30 / 180, 0.001));
    // Only the position listenable changed, so nothing else rebuilt
    expect(notifications, 0);
  });

  testWidgets('moving the slider seeks', (tester) async {
    await pumpControls(tester);
    await playAlbum(tester);

    await tester.tap(find.byType(Slider));
    await tester.pump();

    // A tap in the middle of the slider seeks to the middle of the song
    expect(player.position.inSeconds, closeTo(90, 2));
    expect(player.seeks, hasLength(1));
  });

  testWidgets('dragging the slider seeks once, when let go', (tester) async {
    await pumpControls(tester);
    await playAlbum(tester);
    final slider = find.byType(Slider);
    final box = tester.getRect(slider);

    final gesture = await tester.startGesture(box.centerLeft.translate(24, 0));
    for (var i = 1; i <= 5; i++) {
      await gesture.moveBy(Offset(box.width / 10, 0));
      await tester.pump();
    }

    // The thumb and the time follow the finger, but nothing was seeked yet
    expect(player.seeks, isEmpty);
    final dragged = tester.widget<Slider>(slider).value;
    expect(dragged, greaterThan(0.4));
    final draggedTime = Duration(milliseconds: (dragged * 180000).round());
    expect(
        find.text('${draggedTime.inMinutes}:'
            '${(draggedTime.inSeconds % 60).toString().padLeft(2, '0')}'),
        findsOneWidget);

    // A position update from the player doesn't pull the thumb back
    await tester.runAsync(() async {
      player.simulatePositionChange(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(tester.widget<Slider>(slider).value, dragged);

    await gesture.up();
    await tester.pump();

    expect(player.seeks, hasLength(1));
    expect(player.seeks.single.inMilliseconds / 180000, closeTo(dragged, 0.01));
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
