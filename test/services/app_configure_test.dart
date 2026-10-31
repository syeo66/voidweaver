import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> playerCalls;

  setUp(() {
    playerCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('voidweaver_player'),
            (call) async {
      playerCalls.add(call.method);
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
}
