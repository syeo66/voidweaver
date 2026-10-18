import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The player AppState creates once it's configured
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('voidweaver_player'), (_) async => null);
  });

  const legacy = {
    'server_url': 'https://127.0.0.1:1',
    'username': 'alice',
    'password': 'secret',
  };

  test('moves credentials left in SharedPreferences to secure storage',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(legacy);

    final appState = AppState();
    addTearDown(appState.dispose);
    await appState.initialize();

    expect(appState.isConfigured, isTrue);
    expect(await const FlutterSecureStorage().readAll(), legacy);
    final prefs = await SharedPreferences.getInstance();
    for (final key in legacy.keys) {
      expect(prefs.containsKey(key), isFalse);
    }
  });

  test('stays logged out without credentials', () async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});

    final appState = AppState();
    addTearDown(appState.dispose);
    await appState.initialize();

    expect(appState.isConfigured, isFalse);
  });
}
