import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:voidweaver/services/app_state.dart';
import 'package:voidweaver/widgets/sync_status_indicator.dart';

/// An [AppState] whose sync status is set by the test
class _FakeAppState extends AppState {
  SyncStatus _status = SyncStatus.idle;
  DateTime? _lastSync;

  @override
  SyncStatus get syncStatus => _status;

  @override
  DateTime? get lastSyncTime => _lastSync;

  void set(SyncStatus status, {DateTime? lastSync}) {
    _status = status;
    _lastSync = lastSync;
    notifyListeners();
  }
}

void main() {
  late _FakeAppState appState;

  setUp(() => appState = _FakeAppState());
  tearDown(() => appState.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: appState,
        child: const MaterialApp(
          home: Scaffold(body: Center(child: SyncStatusIndicator())),
        ),
      ),
    );
  }

  String tooltip(WidgetTester tester) =>
      tester.widget<Tooltip>(find.byType(Tooltip)).message!;

  Color iconColor(WidgetTester tester) => tester
      .widget<IconTheme>(
        find
            .descendant(
              of: find.byType(SyncStatusIndicator),
              matching: find.byType(IconTheme),
            )
            .first,
      )
      .data
      .color!;

  testWidgets('shows nothing when idle', (tester) async {
    await pump(tester);

    expect(find.byType(Tooltip), findsNothing);
    expect(find.byType(Icon), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows a spinner while syncing', (tester) async {
    appState.set(SyncStatus.syncing);
    await pump(tester);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tooltip(tester), 'Syncing...');
  });

  testWidgets('shows a green check after a sync', (tester) async {
    appState.set(SyncStatus.success, lastSync: DateTime.now());
    await pump(tester);

    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(tooltip(tester), 'Sync successful');
    expect(iconColor(tester), Colors.green);
  });

  testWidgets('shows an error without a previous success', (tester) async {
    appState.set(SyncStatus.error);
    await pump(tester);

    expect(find.byIcon(Icons.error), findsOneWidget);
    expect(tooltip(tester), 'Sync failed');
    final context = tester.element(find.byType(SyncStatusIndicator));
    expect(iconColor(tester), Theme.of(context).colorScheme.error);
  });

  group('error tooltip shows the last success', () {
    final cases = {
      const Duration(seconds: 30): 'Just now',
      const Duration(minutes: 5): '5m ago',
      const Duration(minutes: 59): '59m ago',
      const Duration(hours: 3): '3h ago',
      const Duration(hours: 23, minutes: 59): '23h ago',
      const Duration(days: 2): '2d ago',
    };
    cases.forEach((age, text) {
      testWidgets(text, (tester) async {
        appState.set(SyncStatus.error, lastSync: DateTime.now().subtract(age));
        await pump(tester);

        expect(tooltip(tester), 'Sync failed (last success: $text)');
      });
    });
  });

  testWidgets('follows status changes', (tester) async {
    await pump(tester);
    expect(find.byType(Tooltip), findsNothing);

    appState.set(SyncStatus.syncing);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    appState.set(SyncStatus.success, lastSync: DateTime.now());
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    appState.set(SyncStatus.idle);
    await tester.pump();
    expect(find.byType(Tooltip), findsNothing);
  });
}
