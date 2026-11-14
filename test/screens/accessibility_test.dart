import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mockito/mockito.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/screens/home_screen.dart';
import 'package:voidweaver/screens/login_screen.dart';
import 'package:voidweaver/screens/settings_screen.dart';
import 'package:voidweaver/services/app_state.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/replaygain_reader.dart';
import 'package:voidweaver/services/settings_service.dart';
import 'package:voidweaver/services/subsonic_api.dart';

import '../test_helpers/fake_audio_cache.dart';
import '../test_helpers/mock_api.dart';
import '../test_helpers/mock_audio_player.dart';
import '../test_helpers/mocks.mocks.dart';

/// Flutter's accessibility guidelines for each screen, in both themes: tap
/// targets of at least 48 dp, a label on everything that can be tapped, and
/// text contrast. The themes are the app's (see `MyApp`).
///
/// A failure names the widget; fix the widget rather than loosening the
/// check here.

/// An [AppState] that is logged in with the given API and player, without a
/// server. Not logged in if both are null.
class _FakeAppState extends AppState {
  final SubsonicApi? _fakeApi;
  final AudioPlayerService? _fakePlayer;
  final SettingsService _fakeSettings;
  final List<Album> _fakeAlbums;

  _FakeAppState(
    this._fakeApi,
    this._fakePlayer,
    this._fakeSettings,
    this._fakeAlbums,
  );

  @override
  SubsonicApi? get api => _fakeApi;

  @override
  AudioPlayerService? get audioPlayerService => _fakePlayer;

  @override
  SettingsService? get settingsService => _fakeSettings;

  @override
  List<Album> get albums => _fakeAlbums;

  @override
  bool get isConfigured => _fakeApi != null;

  @override
  Future<void> clearCaches() async {}
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
    PackageInfo.setMockInitialValues(
      appName: 'Voidweaver',
      packageName: 'red.ochsenbein.voidweaver',
      version: '1.1.0',
      buildNumber: '160',
      buildSignature: '',
    );
    mockApi = newMockApi();
    when(mockApi.getArtists()).thenAnswer((_) async => []);
    when(mockApi.getStreamUrl(any)).thenAnswer(
      (invocation) =>
          'https://music.test/rest/stream?id=${invocation.positionalArguments.first}',
    );
    when(mockApi.readReplayGain(any))
        .thenAnswer((_) async => const ReplayGainData());

    settings = SettingsService();
    await settings.initialize();
    // Offline: preloading downloads nothing
    service = AudioPlayerService(
      mockApi,
      settings,
      audioPlayer: MockAudioPlayer(),
      audioCache: FakeAudioCache()..reachable = false,
    );
    appState = _FakeAppState(mockApi, service, settings, [album]);
  });

  tearDown(() {
    service.dispose();
  });

  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    required Brightness brightness,
    AppState? state,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state ?? appState,
        child: MaterialApp(
          theme: ThemeData(
            colorSchemeSeed: Colors.deepPurple,
            brightness: brightness,
          ),
          home: screen,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> checkGuidelines(WidgetTester tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    } finally {
      // Also when a guideline fails: the test then reports only that, not a
      // leaked semantics handle on top
      semantics.dispose();
    }
  }

  Future<void> openNowPlaying(WidgetTester tester) async {
    await tester.runAsync(() => service.playAlbum(album));
    await tester.pump();
    await tester.tap(find.text('Now Playing'));
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    for (final orientation in Orientation.values) {
      group('in ${brightness.name} ${orientation.name}', () {
        testWidgets('the album list meets the guidelines', (tester) async {
          _setOrientation(tester, orientation);
          await pump(tester, const HomeScreen(), brightness: brightness);

          await checkGuidelines(tester);
        });

        testWidgets('Now Playing meets the guidelines', (tester) async {
          _setOrientation(tester, orientation);
          await pump(tester, const HomeScreen(), brightness: brightness);
          await openNowPlaying(tester);

          await checkGuidelines(tester);
        });

        // The list builds only what's in view, so each section is scrolled to
        testWidgets('every section of Settings meets the guidelines', (
          tester,
        ) async {
          _setOrientation(tester, orientation);
          // ReplayGain's further options only show when it's on
          await settings.setReplayGainMode(ReplayGainMode.track);
          await pump(tester, const SettingsScreen(), brightness: brightness);

          for (final title in [
            'Appearance',
            'Network & Timeouts',
            'Cache',
            'ReplayGain',
            'Scrobbling',
            'Session Log',
          ]) {
            await tester.scrollUntilVisible(
              find.text(title),
              200,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            await checkGuidelines(tester);
          }
          await tester.scrollUntilVisible(
            find.text('Voidweaver 1.1.0 (160)'),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await checkGuidelines(tester);
        });

        testWidgets('the login screen meets the guidelines', (tester) async {
          _setOrientation(tester, orientation);
          await pump(
            tester,
            const LoginScreen(),
            brightness: brightness,
            state: _FakeAppState(null, null, settings, const []),
          );

          await checkGuidelines(tester);
        });
      });
    }
  }
}
