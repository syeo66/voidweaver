import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/screens/settings_screen.dart';
import 'package:voidweaver/services/app_state.dart';
import 'package:voidweaver/services/network_config.dart';
import 'package:voidweaver/services/settings_service.dart';

/// An [AppState] with the given settings and no login; records cache
/// clearing instead of touching the caches.
class _FakeAppState extends AppState {
  final SettingsService _fakeSettings;
  int cachesCleared = 0;

  _FakeAppState(this._fakeSettings);

  @override
  SettingsService? get settingsService => _fakeSettings;

  @override
  Future<void> clearCaches() async => cachesCleared++;
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
      packageName: 'com.example.voidweaver',
      version: '1.1.0',
      buildNumber: '160',
      buildSignature: '',
    );
    settings = SettingsService();
    await settings.initialize();
    appState = _FakeAppState(settings);
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pump();
  }

  Future<void> scrollTo(WidgetTester tester, Finder finder) =>
      tester.scrollUntilVisible(finder, 200,
          scrollable: find.byType(Scrollable).first);

  /// Scrolls until [finder] is built and completely in view, and taps it.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await scrollTo(tester, finder);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
  }

  for (final orientation in Orientation.values) {
    testWidgets('lays out every section in ${orientation.name}',
        (tester) async {
      _setOrientation(tester, orientation);
      await pumpSettings(tester);

      // Scrolling builds each section; an overflow would fail the test
      for (final title in [
        'Appearance',
        'Network & Timeouts',
        'Cache',
        'ReplayGain',
        'ReplayGain Debug Log',
        'Scrobbling',
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

  testWidgets('shows the ReplayGain options only when it is on',
      (tester) async {
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

  testWidgets('applies a connection preset', (tester) async {
    await pumpSettings(tester);
    await tapVisible(tester, find.widgetWithText(ElevatedButton, 'Slow'));
    await tester.pumpAndSettle();

    expect(settings.networkConfig.requestTimeout,
        NetworkConfig.slowConfig.requestTimeout);
    expect(find.text('Slow connection preset applied'), findsOneWidget);
    expect(find.text('${NetworkConfig.slowConfig.requestTimeout.inSeconds}s'),
        findsOneWidget);
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
