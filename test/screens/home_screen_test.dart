import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/screens/home_screen.dart';
import 'package:voidweaver/services/app_state.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/network_errors.dart';
import 'package:voidweaver/services/settings_service.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:voidweaver/services/replaygain_reader.dart';

import '../test_helpers/fake_audio_cache.dart';
import '../test_helpers/mock_audio_player.dart';
import '../test_helpers/mocks.mocks.dart';

/// An [AppState] that is logged in with the given API and player, without
/// a server.
class _FakeAppState extends AppState {
  final SubsonicApi _fakeApi;
  final AudioPlayerService _fakePlayer;
  final List<Album> _fakeAlbums;
  bool loggedOut = false;
  int pending = 0;

  _FakeAppState(this._fakeApi, this._fakePlayer, this._fakeAlbums);

  @override
  int get pendingScrobbles => pending;

  @override
  SubsonicApi? get api => _fakeApi;

  @override
  AudioPlayerService? get audioPlayerService => _fakePlayer;

  @override
  List<Album> get albums => _fakeAlbums;

  @override
  bool get isConfigured => true;

  @override
  Future<void> clearConfiguration() async => loggedOut = true;
}

/// Sets the screen to a phone's size (Pixel 8) in [orientation].
void _setOrientation(WidgetTester tester, Orientation orientation) {
  tester.view.devicePixelRatio = 2.625;
  tester.view.physicalSize = orientation == Orientation.portrait
      ? const Size(1080, 2400)
      : const Size(2400, 1080);
  addTearDown(tester.view.reset);
}

void main() {
  late MockSubsonicApi mockApi;
  late SettingsService settings;
  late AudioPlayerService service;
  late _FakeAppState appState;

  // Without cover art, so no image is loaded, and with ReplayGain data, so
  // it isn't read from the file
  Song song(String id) => Song(
        id: id,
        title: 'Title $id',
        artist: 'Artist $id',
        album: 'Album $id',
        duration: 180,
        replayGainTrackGain: -6.0,
      );

  final album = Album(
    id: 'album1',
    name: 'First Album',
    artist: 'Album Artist',
    songs: [song('s1'), song('s2')],
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockSubsonicApi();
    when(mockApi.getArtists()).thenAnswer((_) async => []);
    when(mockApi.getStreamUrl(any)).thenAnswer((invocation) =>
        'https://music.test/rest/stream?id=${invocation.positionalArguments.first}');
    when(mockApi.readReplayGain(any))
        .thenAnswer((_) async => const ReplayGainData());

    settings = SettingsService();
    await settings.initialize();
    // Offline: preloading downloads nothing
    service = AudioPlayerService(mockApi, settings,
        audioPlayer: MockAudioPlayer(),
        audioCache: FakeAudioCache()..reachable = false);
    appState = _FakeAppState(mockApi, service, [album]);
  });

  tearDown(() {
    service.dispose();
  });

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: const MaterialApp(home: HomeScreen()),
    ));
    await tester.pump();
  }

  Future<void> playAlbum(WidgetTester tester) async {
    await tester.runAsync(() => service.playAlbum(album));
    await tester.pump();
  }

  Future<void> openNowPlaying(WidgetTester tester) async {
    await tester.tap(find.text('Now Playing'));
    // Lets the scroll to the current track run
    await tester.pumpAndSettle();
  }

  for (final orientation in Orientation.values) {
    group('in ${orientation.name}', () {
      testWidgets('shows the albums first', (tester) async {
        _setOrientation(tester, orientation);
        await pumpHome(tester);

        expect(find.text('First Album'), findsOneWidget);
        expect(find.text('No song playing'), findsNothing);
      });

      testWidgets('Now Playing says so when nothing plays', (tester) async {
        _setOrientation(tester, orientation);
        await pumpHome(tester);
        await openNowPlaying(tester);

        expect(find.text('No song playing'), findsOneWidget);
      });

      testWidgets('Now Playing shows the song and the playlist',
          (tester) async {
        _setOrientation(tester, orientation);
        await pumpHome(tester);
        await playAlbum(tester);
        await openNowPlaying(tester);

        final portrait = orientation == Orientation.portrait;
        // The song info and the player controls; in portrait also under its
        // cover in the playlist
        expect(find.text('Title s1'), findsNWidgets(portrait ? 3 : 2));
        expect(find.text('Album s1'), findsOneWidget);
        expect(find.text('Title s2'), portrait ? findsOneWidget : findsNothing);
        // A phone in landscape has only room for the covers, not the label
        expect(find.text('Playlist: 1 of 2'),
            portrait ? findsOneWidget : findsNothing);
        expect(find.byKey(const ValueKey('playlist-item-s1')), findsOneWidget);
        expect(find.byKey(const ValueKey('playlist-item-s2')), findsOneWidget);
      });

      testWidgets('Now Playing follows a skip', (tester) async {
        _setOrientation(tester, orientation);
        await pumpHome(tester);
        await playAlbum(tester);
        await openNowPlaying(tester);

        await tester.runAsync(() async {
          await service.next();
        });
        await tester.pumpAndSettle();

        expect(find.text('Album s2'), findsOneWidget);
        if (orientation == Orientation.portrait) {
          expect(find.text('Playlist: 2 of 2'), findsOneWidget);
        }
      });
    });
  }

  testWidgets('a tablet in landscape has room for the playlist label',
      (tester) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(2560, 1600);
    addTearDown(tester.view.reset);
    await pumpHome(tester);
    await playAlbum(tester);
    await openNowPlaying(tester);

    expect(find.text('Playlist: 1 of 2'), findsOneWidget);
    expect(find.byKey(const ValueKey('playlist-item-s2')), findsOneWidget);
  });

  testWidgets('the sleep timer can be started and cancelled', (tester) async {
    await pumpHome(tester);
    expect(find.byIcon(Icons.bedtime_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.bedtime_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, '30m'));
    await tester.pumpAndSettle();

    expect(service.isSleepTimerActive, isTrue);
    expect(service.sleepTimerDuration, const Duration(minutes: 30));
    // In the app bar; the player controls are hidden without a song
    expect(find.byIcon(Icons.bedtime), findsOneWidget);

    await tester.tap(find.byIcon(Icons.bedtime));
    await tester.pumpAndSettle();
    expect(find.text('Timer Active'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(service.isSleepTimerActive, isFalse);
    expect(find.byIcon(Icons.bedtime_outlined), findsOneWidget);
  });

  testWidgets('shows why random songs could not be played', (tester) async {
    when(mockApi.getRandomSongs(any)).thenAnswer(
        (_) async => throw const UserFacingException('Server is down'));
    await pumpHome(tester);

    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.shuffle));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();

    expect(find.text('Failed to play random songs: Server is down'),
        findsOneWidget);
    // The button is enabled again
    expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.shuffle))
            .onPressed,
        isNotNull);
  });

  Future<void> openLogout(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logout'));
    await tester.pumpAndSettle();
  }

  testWidgets('logs out from the menu once confirmed', (tester) async {
    await pumpHome(tester);
    await openLogout(tester);

    expect(find.text('Log out?'), findsOneWidget);
    expect(find.textContaining('sent to the server'), findsNothing);
    expect(appState.loggedOut, isFalse);

    await tester.tap(find.widgetWithText(TextButton, 'Log out'));
    await tester.pumpAndSettle();

    expect(appState.loggedOut, isTrue);
  });

  testWidgets('cancelling the logout keeps the login', (tester) async {
    await pumpHome(tester);
    await openLogout(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Log out?'), findsNothing);
    expect(appState.loggedOut, isFalse);
  });

  testWidgets('the logout warns about plays not yet scrobbled', (tester) async {
    appState.pending = 3;
    await pumpHome(tester);
    await openLogout(tester);

    expect(
        find.textContaining(
            '3 plays haven\'t been sent to the server yet and will be lost.'),
        findsOneWidget);
  });
}
