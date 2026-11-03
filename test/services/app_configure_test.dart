import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/app_state.dart';

import '../test_helpers/saved_credentials.dart';
import 'package:voidweaver/services/network_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> playerCalls;
  late List<Object?> timeoutCalls;

  setUp(() {
    playerCalls = [];
    timeoutCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('voidweaver_player'),
            (call) async {
      playerCalls.add(call.method);
      if (call.method == 'network.setTimeouts') {
        timeoutCalls.add(call.arguments);
      }
      return null;
    });
    SharedPreferences.setMockInitialValues({});
  });

  test('a login whose credentials cannot be saved releases its services',
      () async {
    // The fake storage writes into this map, so every write throws
    FlutterSecureStorage.setMockInitialValues(const {});

    final appState = AppState();
    addTearDown(appState.dispose);
    await appState.initialize();
    expect(appState.isConfigured, isFalse);

    await expectLater(
      appState.configure('https://127.0.0.1:1', 'alice', 'secret'),
      throwsA(isA<UnsupportedError>()),
    );

    expect(appState.isConfigured, isFalse);
    expect(appState.configurationLoadingState, LoadingState.error);
    expect(appState.api, isNull);
    expect(appState.audioPlayerService, isNull);
    // The player, and with it the media session, was released
    await pumpEventQueue();
    expect(playerCalls, contains('dispose'));
  });

  test('starting with saved credentials does not write them again', () async {
    // Every write throws, as above: one would fail the start and log out
    FlutterSecureStorage.setMockInitialValues(Map.unmodifiable(
        savedCredentials('https://127.0.0.1:1', 'alice', 'secret')));

    final appState = AppState();
    addTearDown(appState.dispose);
    await appState.initialize();

    expect(appState.isConfigured, isTrue);
    expect(appState.api!.serverUrl, 'https://127.0.0.1:1');
  });

  test('stays logged out without credentials', () async {
    FlutterSecureStorage.setMockInitialValues({});

    final appState = AppState();
    addTearDown(appState.dispose);
    await appState.initialize();

    expect(appState.isConfigured, isFalse);
  });

  test('hands the connection and streaming timeouts to the player', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final appState = AppState();
    addTearDown(appState.dispose);
    await appState.initialize();
    await pumpEventQueue();

    expect(timeoutCalls, [
      {'connect': 15000, 'read': 60000}
    ]);

    // Another setting: nothing new to send
    await appState.settingsService!.setReplayGainPreamp(2.0);
    await pumpEventQueue();
    expect(timeoutCalls, hasLength(1));

    await appState.settingsService!.setNetworkConfig(NetworkConfig.slowConfig);
    await pumpEventQueue();
    expect(timeoutCalls.last, {'connect': 30000, 'read': 120000});
  });
}
