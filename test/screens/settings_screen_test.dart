import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/screens/settings_screen.dart';
import 'package:voidweaver/services/app_state.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/network_config.dart';
import 'package:voidweaver/services/settings_service.dart';
import 'package:voidweaver/widgets/settings/setting_slider.dart';

/// An [AppState] with the given settings and no login; records cache
/// clearing instead of touching the caches.
class _FakeAppState extends AppState {
  final SettingsService _fakeSettings;

  /// No player unless a test sets one, like no login.
  _FakePlayer? player;
  int cachesCleared = 0;

  _FakeAppState(this._fakeSettings);

  @override
  SettingsService? get settingsService => _fakeSettings;

  @override
  AudioPlayerService? get audioPlayerService => player;

  @override
  Future<void> clearCaches() async => cachesCleared++;
}

/// Counts how often changed ReplayGain settings are applied to the queue.
class _FakePlayer extends Fake implements AudioPlayerService {
  int gainRefreshes = 0;

  @override
  Future<void> refreshReplayGainVolume() async => gainRefreshes++;
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
  late SettingsService settings;
  late _FakeAppState appState;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Voidweaver',
      packageName: 'red.ochsenbein.voidweaver',
      version: '1.1.0',
      buildNumber: '160',
      buildSignature: '',
    );
    settings = SettingsService();
    await settings.initialize();
    appState = _FakeAppState(settings);
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: appState,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
  }

  Future<void> scrollTo(WidgetTester tester, Finder finder) =>
      tester.scrollUntilVisible(
        finder,
        200,
        scrollable: find.byType(Scrollable).first,
      );

  /// Scrolls until [finder] is built and completely in view, and taps it.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await scrollTo(tester, finder);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
  }

  for (final orientation in Orientation.values) {
    testWidgets('lays out every section in ${orientation.name}', (
      tester,
    ) async {
      _setOrientation(tester, orientation);
      await pumpSettings(tester);

      // Scrolling builds each section; an overflow would fail the test
      for (final title in [
        'Appearance',
        'Network & Timeouts',
        'Cache',
        'ReplayGain',
        'Scrobbling',
        'Session Log',
      ]) {
        await scrollTo(tester, find.text(title));
        expect(find.text(title), findsOneWidget);
      }
      await scrollTo(tester, find.text('Voidweaver 1.1.0 (160)'));
    });
  }

  testWidgets('changes the theme', (tester) async {
    await pumpSettings(tester);

    await tapVisible(tester, find.text('Dark'));
    await tester.pump();

    expect(settings.themeMode, ThemeMode.dark);
  });

  testWidgets('shows the ReplayGain options only when it is on', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tapVisible(tester, find.text('Off'));
    await tester.pump();
    expect(settings.replayGainMode, ReplayGainMode.off);
    expect(find.textContaining('Preamp:'), findsNothing);

    await tapVisible(tester, find.text('Track'));
    await tester.pump();
    expect(settings.replayGainMode, ReplayGainMode.track);
    await scrollTo(tester, find.text('Prevent Clipping'));
    expect(find.textContaining('Preamp:'), findsOneWidget);
  });

  testWidgets('a slider saves its setting once, when the drag ends', (
    tester,
  ) async {
    await pumpSettings(tester);
    final before = settings.scrobbleThresholdPercent;
    final threshold = find.descendant(
      of: find.byWidgetPredicate(
        (widget) => widget is SettingSlider && widget.title == 'Threshold',
      ),
      matching: find.byType(Slider),
    );
    await scrollTo(tester, find.textContaining('Threshold:'));
    await tester.ensureVisible(threshold);
    await tester.pumpAndSettle();
    var saves = 0;
    settings.addListener(() => saves++);

    final drag = await tester.startGesture(tester.getCenter(threshold));
    for (var i = 0; i < 5; i++) {
      await drag.moveBy(const Offset(-20, 0));
      await tester.pump();
    }
    // The title follows the drag; nothing is saved yet
    expect(find.text('Threshold: ${before.round()}%'), findsNothing);
    expect(settings.scrobbleThresholdPercent, before);
    expect(saves, 0);

    await drag.up();
    await tester.pumpAndSettle();
    final after = settings.scrobbleThresholdPercent;
    expect(after, lessThan(before));
    expect(saves, 1);
    expect(find.text('Threshold: ${after.round()}%'), findsOneWidget);
  });

  testWidgets('a ReplayGain slider applies its value once, when released', (
    tester,
  ) async {
    await settings.setReplayGainMode(ReplayGainMode.track);
    final player = appState.player = _FakePlayer();
    await pumpSettings(tester);
    final before = settings.replayGainPreamp;
    final preamp = find.descendant(
      of: find.byWidgetPredicate(
        (widget) => widget is SettingSlider && widget.title == 'Preamp',
      ),
      matching: find.byType(Slider),
    );
    await scrollTo(tester, find.textContaining('Preamp:'));
    await tester.ensureVisible(preamp);
    await tester.pumpAndSettle();

    final drag = await tester.startGesture(tester.getCenter(preamp));
    for (var i = 0; i < 5; i++) {
      await drag.moveBy(const Offset(20, 0));
      await tester.pump();
    }
    expect(player.gainRefreshes, 0);
    expect(settings.replayGainPreamp, before);

    await drag.up();
    await tester.pumpAndSettle();
    expect(settings.replayGainPreamp, greaterThan(before));
    expect(player.gainRefreshes, 1);
  });

  testWidgets('applies a connection preset', (tester) async {
    await pumpSettings(tester);
    await tapVisible(tester, find.widgetWithText(ElevatedButton, 'Slow'));
    await tester.pumpAndSettle();

    expect(
      settings.networkConfig.requestTimeout,
      NetworkConfig.slowConfig.requestTimeout,
    );
    expect(find.text('Slow connection preset applied'), findsOneWidget);
    expect(
      find.text('${NetworkConfig.slowConfig.requestTimeout.inSeconds}s'),
      findsOneWidget,
    );
  });

  testWidgets('clears the cache only once confirmed', (tester) async {
    await pumpSettings(tester);
    await tapVisible(tester, find.text('Clear Cache'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(appState.cachesCleared, 0);

    await tapVisible(tester, find.text('Clear Cache'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Clear'));
    await tester.pumpAndSettle();

    expect(appState.cachesCleared, 1);
    expect(find.text('Cache cleared'), findsOneWidget);
  });
}
