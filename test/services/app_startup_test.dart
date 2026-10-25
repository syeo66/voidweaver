import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState appState;

  setUp(() async {
    // The player AppState creates once it's configured
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('voidweaver_player'), (_) async => null);
    // Nothing listens there, so loading the albums fails after its retries
    FlutterSecureStorage.setMockInitialValues({
      'server_url': 'https://127.0.0.1:1',
      'username': 'alice',
      'password': 'secret',
    });
    SharedPreferences.setMockInitialValues({});

    appState = AppState();
    addTearDown(appState.dispose);
    await appState.initialize();
  });

  Future<void> albumsLoaded() async {
    while (appState.isLoading) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('starts with saved credentials before the albums have loaded', () async {
    expect(appState.isConfigured, isTrue);
    expect(appState.isLoading, isTrue);

    await albumsLoaded();
    expect(appState.albumError, isNotNull);
  });

  test('a logout drops the album load in progress', () async {
    // Logging out clears the cover art cache, which lives there
    final temp = await Directory.systemTemp.createTemp();
    addTearDown(() => temp.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => temp.path);

    var notified = false;
    await appState.clearConfiguration();
    appState.addListener(() => notified = true);
    expect(appState.isLoading, isFalse);

    // Longer than the load takes to fail
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(notified, isFalse);
    expect(appState.albumError, isNull);
  });
}
