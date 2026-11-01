import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/screens/advanced_network_dialog.dart';
import 'package:voidweaver/services/network_config.dart';
import 'package:voidweaver/services/settings_service.dart';

/// A [SettingsService] whose [setNetworkConfig] fails, like a storage error
class _FailingSettingsService extends SettingsService {
  @override
  Future<void> setNetworkConfig(NetworkConfig config) async {
    throw StateError('storage unavailable');
  }
}

// The dialog's text fields, in the order it shows them
const _connection = 0;
const _request = 1;
const _metadata = 2;
const _streaming = 3;
const _retries = 4;

void main() {
  late SettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService();
    await settings.initialize();
  });

  /// Opens the dialog from a screen with a Scaffold, like the settings screen
  Future<void> openDialog(WidgetTester tester,
      [SettingsService? service]) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AdvancedNetworkSettingsDialog(
                settingsService: service ?? settings,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder field(int index) => find.byType(TextField).at(index);

  String fieldText(WidgetTester tester, int index) =>
      tester.widget<TextField>(field(index)).controller!.text;

  Future<void> enter(WidgetTester tester, int index, String text) =>
      tester.enterText(field(index), text);

  Future<void> tapInDialog(WidgetTester tester, String label) async {
    final finder = find.text(label);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  bool switchValue(WidgetTester tester, String title) => tester
      .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title))
      .value;

  testWidgets('shows the saved config', (tester) async {
    await settings.setNetworkConfig(NetworkConfig.slowConfig.copyWith(
      enableRetryOnTimeout: false,
    ));
    await openDialog(tester);

    expect(fieldText(tester, _connection), '30');
    expect(fieldText(tester, _request), '60');
    expect(fieldText(tester, _metadata), '45');
    expect(fieldText(tester, _streaming), '120');
    expect(fieldText(tester, _retries), '5');
    expect(switchValue(tester, 'Retry on Timeout'), isFalse);
    expect(switchValue(tester, 'Retry on Connection Error'), isTrue);
  });

  testWidgets('saves the edited values, closes and confirms', (tester) async {
    await openDialog(tester);

    await enter(tester, _connection, '5');
    await enter(tester, _request, '40');
    await enter(tester, _metadata, '25');
    await enter(tester, _streaming, ' 90 '); // surrounding spaces are ignored
    await enter(tester, _retries, '0');
    await tapInDialog(tester, 'Retry on Timeout');
    await tapInDialog(tester, 'Retry on Connection Error');
    await tapInDialog(tester, 'Save');

    final config = settings.networkConfig;
    expect(config.connectionTimeout, const Duration(seconds: 5));
    expect(config.requestTimeout, const Duration(seconds: 40));
    expect(config.metadataTimeout, const Duration(seconds: 25));
    expect(config.streamingTimeout, const Duration(seconds: 90));
    expect(config.maxRetryAttempts, 0);
    expect(config.enableRetryOnTimeout, isFalse);
    expect(config.enableRetryOnConnectionError, isFalse);

    expect(find.byType(AdvancedNetworkSettingsDialog), findsNothing);
    expect(find.text('Network settings saved successfully'), findsOneWidget);
  });

  testWidgets('keeps the settings it does not show', (tester) async {
    await settings.setNetworkConfig(NetworkConfig.slowConfig);
    await openDialog(tester);

    await enter(tester, _connection, '20');
    await tapInDialog(tester, 'Save');

    final config = settings.networkConfig;
    expect(config.connectionTimeout, const Duration(seconds: 20));
    expect(config.maxRetryDelay, NetworkConfig.slowConfig.maxRetryDelay);
    expect(
        config.initialRetryDelay, NetworkConfig.slowConfig.initialRetryDelay);
    expect(config.retryBackoffMultiplier,
        NetworkConfig.slowConfig.retryBackoffMultiplier);
  });

  testWidgets('Reset to Defaults fills in the defaults, saved with Save',
      (tester) async {
    await settings.setNetworkConfig(NetworkConfig.slowConfig.copyWith(
      enableRetryOnTimeout: false,
      enableRetryOnConnectionError: false,
    ));
    await openDialog(tester);

    await tapInDialog(tester, 'Reset to Defaults');

    const defaults = NetworkConfig.defaultConfig;
    expect(fieldText(tester, _connection),
        '${defaults.connectionTimeout.inSeconds}');
    expect(fieldText(tester, _request), '${defaults.requestTimeout.inSeconds}');
    expect(
        fieldText(tester, _metadata), '${defaults.metadataTimeout.inSeconds}');
    expect(fieldText(tester, _streaming),
        '${defaults.streamingTimeout.inSeconds}');
    expect(fieldText(tester, _retries), '${defaults.maxRetryAttempts}');
    expect(
        switchValue(tester, 'Retry on Timeout'), defaults.enableRetryOnTimeout);
    expect(switchValue(tester, 'Retry on Connection Error'),
        defaults.enableRetryOnConnectionError);
    // Nothing is saved before Save
    expect(settings.networkConfig.maxRetryAttempts,
        NetworkConfig.slowConfig.maxRetryAttempts);

    await tapInDialog(tester, 'Save');

    final config = settings.networkConfig;
    expect(config.connectionTimeout, defaults.connectionTimeout);
    expect(config.maxRetryAttempts, defaults.maxRetryAttempts);
    expect(config.enableRetryOnTimeout, defaults.enableRetryOnTimeout);
    // Also the settings the dialog doesn't show
    expect(config.maxRetryDelay, defaults.maxRetryDelay);
  });

  testWidgets('Cancel closes without saving', (tester) async {
    await openDialog(tester);

    await enter(tester, _connection, '99');
    await tapInDialog(tester, 'Cancel');

    expect(find.byType(AdvancedNetworkSettingsDialog), findsNothing);
    expect(settings.networkConfig.connectionTimeout,
        NetworkConfig.defaultConfig.connectionTimeout);
  });

  group('rejects', () {
    final cases = <String, (int, String, String)>{
      'text': (_request, 'abc', 'Invalid input: Please enter valid numbers'),
      'an empty field': (
        _retries,
        '',
        'Invalid input: Please enter valid numbers'
      ),
      'a decimal': (
        _metadata,
        '2.5',
        'Invalid input: Please enter valid numbers'
      ),
      'connection timeout 0': (
        _connection,
        '0',
        'Connection timeout must be between 1 and 300 seconds'
      ),
      'connection timeout 301': (
        _connection,
        '301',
        'Connection timeout must be between 1 and 300 seconds'
      ),
      'request timeout 601': (
        _request,
        '601',
        'Request timeout must be between 1 and 600 seconds'
      ),
      'metadata timeout 0': (
        _metadata,
        '0',
        'Metadata timeout must be between 1 and 300 seconds'
      ),
      'streaming timeout 1201': (
        _streaming,
        '1201',
        'Streaming timeout must be between 1 and 1200 seconds'
      ),
      'negative retries': (
        _retries,
        '-1',
        'Max retries must be between 0 and 10'
      ),
      '11 retries': (_retries, '11', 'Max retries must be between 0 and 10'),
    };

    cases.forEach((name, testCase) {
      final (index, input, message) = testCase;
      testWidgets(name, (tester) async {
        await openDialog(tester);

        await enter(tester, index, input);
        await tapInDialog(tester, 'Save');

        expect(find.text(message), findsOneWidget);
        // The dialog stays open, so the input can be corrected
        expect(find.byType(AdvancedNetworkSettingsDialog), findsOneWidget);
        expect(settings.networkConfig.toJson(),
            NetworkConfig.defaultConfig.toJson());
      });
    });

    testWidgets('accepts the bounds', (tester) async {
      await openDialog(tester);

      await enter(tester, _connection, '300');
      await enter(tester, _request, '600');
      await enter(tester, _metadata, '1');
      await enter(tester, _streaming, '1200');
      await enter(tester, _retries, '10');
      await tapInDialog(tester, 'Save');

      expect(find.byType(AdvancedNetworkSettingsDialog), findsNothing);
      expect(settings.networkConfig.streamingTimeout,
          const Duration(seconds: 1200));
      expect(settings.networkConfig.maxRetryAttempts, 10);
    });
  });

  testWidgets('a failed save keeps the dialog open and says so',
      (tester) async {
    final failing = _FailingSettingsService();
    await failing.initialize();
    await openDialog(tester, failing);

    await tapInDialog(tester, 'Save');

    expect(find.text('Could not save the network settings'), findsOneWidget);
    expect(
        find.text('Invalid input: Please enter valid numbers'), findsNothing);
    expect(find.byType(AdvancedNetworkSettingsDialog), findsOneWidget);
  });
}
