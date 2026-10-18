// This is a basic Flutter widget test for Voidweaver.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:voidweaver/main.dart';
import 'package:voidweaver/services/app_state.dart';

void main() {
  testWidgets('App can be instantiated without errors',
      (WidgetTester tester) async {
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

  testWidgets('App supports both light and dark themes',
      (WidgetTester tester) async {
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
    for (var i = 0;
        i < 50 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }

    ThemeMode themeMode() =>
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode!;

    // The saved setting applies once the app is initialized
    expect(themeMode(), equals(ThemeMode.dark));

    final appState = Provider.of<AppState>(
        tester.element(find.byType(AppRouter)),
        listen: false);
    await appState.settingsService!.setThemeMode(ThemeMode.light);
    await tester.pump();
    expect(themeMode(), equals(ThemeMode.light));
  });
}
