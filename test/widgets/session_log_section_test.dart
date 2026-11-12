import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/session_log.dart';
import 'package:voidweaver/widgets/settings/session_log_section.dart';

void main() {
  late Directory temp;
  final log = SessionLog.instance;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('session_log_section_test');
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => temp.path,
        );
    log.appVersion = () async => 'Voidweaver 1.2.4 (2)';
  });

  tearDown(() async {
    await log.resetForTest();
    temp.deleteSync(recursive: true);
  });

  Future<void> show(WidgetTester tester) => tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: SessionLogSection())),
    ),
  );

  testWidgets('has no switch: the log always records', (tester) async {
    await show(tester);

    expect(find.text('Session Log'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('Export'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);
  });

  testWidgets('shows the previous run\'s size when there is one', (
    tester,
  ) async {
    await tester.runAsync(() async {
      File('${temp.path}/${SessionLog.fileName}').writeAsStringSync('x' * 2048);
      await log.start();
    });
    // The card reads the previous run's size from the file: real I/O
    await tester.runAsync(() async {
      await show(tester);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(find.textContaining('Previous run: 2'), findsOneWidget);
  });

  testWidgets('Clear asks first; Cancel keeps the log', (tester) async {
    await tester.runAsync(() async {
      await log.start();
      log.add(LogRecord(Level.INFO, 'something happened', 'test'));
      await log.flush();
    });
    final size = log.sizeBytes;
    expect(size, greaterThan(0));
    await show(tester);

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Clear Session Log?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Clear Session Log?'), findsNothing);
    // Emptying it is covered by session_log_test.dart
    expect(log.sizeBytes, size);
  });
}
