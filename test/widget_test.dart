// This is a basic Flutter widget test for Voidweaver.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:voidweaver/main.dart';
import 'package:voidweaver/services/app_state.dart';

import 'test_helpers/waiting.dart';

void main() {
  testWidgets('App can be instantiated without errors', (
    WidgetTester tester,
  ) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    // Give it a moment to start initializing
    await tester.pump();

    // Verify that the app scaffold is created (basic smoke test)
    expect(find.byType(Scaffold), findsAtLeastNWidgets(1));

    // Should show the login screen initially
    expect(find.byType(MaterialApp), findsOneWidget);

    // Should have a title
    final MaterialApp app = tester.widget(find.byType(MaterialApp));
    expect(app.title, equals('Voidweaver'));
  });

  testWidgets('App supports both light and dark themes', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    final MaterialApp app = tester.widget(find.byType(MaterialApp));
    expect(app.theme, isNotNull);
    expect(app.darkTheme, isNotNull);
    expect(app.themeMode, equals(ThemeMode.system));
  });

  testWidgets('App follows the theme setting', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'themeMode': ThemeMode.dark.index});
    await tester.pumpWidget(const MyApp());
    // Initialization does real I/O, so let it run outside the fake clock
    await pumpFramesUntil(
      tester,
      () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      reason: 'the app to be initialized',
    );

    ThemeMode themeMode() =>
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode!;

    // The saved setting applies once the app is initialized
    expect(themeMode(), equals(ThemeMode.dark));

    final appState = Provider.of<AppState>(
      tester.element(find.byType(AppRouter)),
      listen: false,
    );
    await appState.settingsService!.setThemeMode(ThemeMode.light);
    await tester.pump();
    expect(themeMode(), equals(ThemeMode.light));
  });

  testWidgets('App offers a retry when its saved data can\'t be read', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final working = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = _FailingStore(working);

    bool loading() =>
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
    bool offersRetry() => find.text('Try again').evaluate().isNotEmpty;

    await tester.pumpWidget(const MyApp());
    // Initialization does real I/O, so let it run outside the fake clock
    await pumpFramesUntil(
      tester,
      () => !loading() && offersRetry(),
      reason: 'the retry to be offered',
    );

    expect(find.text('Try again'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // The storage works again
    SharedPreferencesStorePlatform.instance = working;
    await tester.tap(find.text('Try again'));
    await pumpFramesUntil(
      tester,
      () => !loading() && !offersRetry(),
      reason: 'the app to be initialized',
    );

    expect(find.text('Try again'), findsNothing);
    expect(
      find.text('Voidweaver could not read its saved data.'),
      findsNothing,
    );
  });
}

/// A store that can't be read
class _FailingStore extends SharedPreferencesStorePlatform {
  _FailingStore(this._working);

  final SharedPreferencesStorePlatform _working;

  @override
  Future<Map<String, Object>> getAll() async =>
      throw StateError('storage unavailable');

  @override
  Future<bool> clear() => _working.clear();

  @override
  Future<bool> remove(String key) => _working.remove(key);

  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      _working.setValue(valueType, key, value);
}
