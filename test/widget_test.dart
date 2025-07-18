// This is a basic Flutter widget test for Voidweaver.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:voidweaver/main.dart';

void main() {
  testWidgets('App can be instantiated without errors', (WidgetTester tester) async {
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
  
  testWidgets('App supports both light and dark themes', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();
    
    final MaterialApp app = tester.widget(find.byType(MaterialApp));
    expect(app.theme, isNotNull);
    expect(app.darkTheme, isNotNull);
    expect(app.themeMode, equals(ThemeMode.system));
  });
}