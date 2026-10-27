import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/models/album_list_type.dart';
import 'package:voidweaver/services/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState appState;

  setUp(() async {
    // The player AppState creates once it's configured
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('voidweaver_player'), (_) async => null);
    // Nothing listens there, so every request fails and no sync succeeds
    FlutterSecureStorage.setMockInitialValues({
      'server_url': 'https://127.0.0.1:1',
      'username': 'alice',
      'password': 'secret',
    });
    SharedPreferences.setMockInitialValues({});

    appState = AppState();
    addTearDown(appState.dispose);
    await appState.initialize();
    expect(appState.isConfigured, isTrue);
  });

  /// Waits for a running sync to fail, so it doesn't outlive the test.
  Future<void> syncFinished() async {
    while (appState.syncStatus == SyncStatus.syncing) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('a due sync runs when the app is shown again', () async {
    appState.setVisible(false);
    expect(appState.syncStatus, SyncStatus.idle);

    appState.setVisible(true);
    expect(appState.syncStatus, SyncStatus.syncing);
    await syncFinished();
    expect(appState.syncStatus, SyncStatus.error);
  });

  test('a sync of the order switched away from leaves the new one alone',
      () async {
    appState.setVisible(false);
    appState.setVisible(true);
    expect(appState.syncStatus, SyncStatus.syncing);
    await appState.setAlbumListType(AlbumListType.newest);
    await syncFinished();

    // The load for the new order reports its failure, not the old sync
    expect(appState.syncStatus, SyncStatus.idle);
    expect(appState.error, isNotNull);
  });

  test('staying visible starts no extra sync', () {
    appState.setVisible(true);
    expect(appState.syncStatus, SyncStatus.idle);
  });
}
