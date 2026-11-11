import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/app_state.dart';

import '../test_helpers/saved_credentials.dart';
import '../test_helpers/waiting.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState appState;
  // The calls on the player plugin's channel, by method
  late List<String> pluginCalls;

  setUp(() async {
    pluginCalls = [];
    // The player AppState creates once it's configured
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('voidweaver_player'), (
          call,
        ) async {
          pluginCalls.add(call.method);
          return null;
        });
    // Nothing listens there, so loading the albums fails after its retries
    FlutterSecureStorage.setMockInitialValues(
      savedCredentials('https://127.0.0.1:1', 'alice', 'secret'),
    );
    SharedPreferences.setMockInitialValues({});

    appState = AppState();
    addTearDown(appState.dispose);
    await appState.initialize();
  });

  Future<void> albumsLoaded() =>
      pumpUntil(() => !appState.isLoading, reason: 'the albums to load');

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
          (_) async => temp.path,
        );

    var notified = false;
    await appState.clearConfiguration();
    appState.addListener(() => notified = true);
    expect(appState.isLoading, isFalse);

    // Longer than the load takes to fail. Nothing shows that the dropped load
    // ended; too short a wait could only let the check pass (see
    // test/README.md).
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(notified, isFalse);
    expect(appState.albumError, isNull);
  });

  test('a logout removes the downloaded audio, after releasing the '
      'player', () async {
    final temp = await Directory.systemTemp.createTemp();
    addTearDown(() => temp.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => temp.path,
        );

    await appState.clearConfiguration();

    final released = pluginCalls.indexOf('dispose');
    expect(released, isNot(-1));
    expect(pluginCalls.indexOf('cache.clear'), greaterThan(released));
  });

  test(
    'a logout that cannot remove the credentials still clears the rest',
    () async {
      final temp = await Directory.systemTemp.createTemp();
      addTearDown(() => temp.delete(recursive: true));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => temp.path,
          );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('playbackQueue', '{}');
      FlutterSecureStoragePlatform.instance = _FailingDeleteStorage();

      await appState.clearConfiguration();

      expect(appState.isConfigured, isFalse);
      expect(prefs.containsKey('playbackQueue'), isFalse);
    },
  );
}

/// Secure storage whose deleteAll() fails, like a Keystore error
class _FailingDeleteStorage extends TestFlutterSecureStoragePlatform {
  _FailingDeleteStorage() : super({});

  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      throw PlatformException(code: 'keystore', message: 'unavailable');
}
