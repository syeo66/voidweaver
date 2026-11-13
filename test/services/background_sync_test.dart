import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/models/album_list_type.dart';
import 'package:voidweaver/services/app_state.dart';

import '../test_helpers/fake_subsonic_server.dart';
import '../test_helpers/saved_credentials.dart';
import '../test_helpers/waiting.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState appState;

  setUp(() {
    // The player AppState creates once it's configured
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('voidweaver_player'),
          (_) async => null,
        );
    SharedPreferences.setMockInitialValues({});
  });

  /// Waits for a running sync to end, so it doesn't outlive the test.
  Future<void> syncFinished() => pumpUntil(
    () => appState.syncStatus != SyncStatus.syncing,
    reason: 'the sync to finish',
  );

  /// Hides the app and shows it again, which syncs if a sync is due
  void showAgain() => appState
    ..setVisible(false)
    ..setVisible(true);

  group('with the server unreachable', () {
    setUp(() async {
      // Nothing listens there, so every request fails and no sync succeeds
      FlutterSecureStorage.setMockInitialValues(
        savedCredentials('https://127.0.0.1:1', 'alice', 'secret'),
      );

      appState = AppState();
      addTearDown(appState.dispose);
      await appState.initialize();
      expect(appState.isConfigured, isTrue);
    });

    test('a due sync runs when the app is shown again', () async {
      appState.setVisible(false);
      expect(appState.syncStatus, SyncStatus.idle);

      appState.setVisible(true);
      expect(appState.syncStatus, SyncStatus.syncing);
      await syncFinished();
      expect(appState.syncStatus, SyncStatus.error);
    });

    test(
      'a sync of the order switched away from leaves the new one alone',
      () async {
        showAgain();
        expect(appState.syncStatus, SyncStatus.syncing);
        await appState.setAlbumListType(AlbumListType.newest);
        await syncFinished();

        // The load for the new order reports its failure, not the old sync
        expect(appState.syncStatus, SyncStatus.idle);
        expect(appState.albumError, isNotNull);
      },
    );

    test('staying visible starts no extra sync', () {
      appState.setVisible(true);
      expect(appState.syncStatus, SyncStatus.idle);
    });
  });

  // When a sync is due, by the age of the album list: AppState's clock,
  // which the API cache's expiry follows too. Checked by showing the app
  // again (the periodic timer runs on real time and asks the same question).
  group('against the fake server', () {
    late FakeSubsonicServer server;
    late HttpOverrides? previousOverrides;
    late DateTime now;

    setUp(() async {
      previousOverrides = HttpOverrides.current;
      HttpOverrides.global = FakeSubsonicServer.httpOverrides;
      server = FakeSubsonicServer();
      await server.start();
      FlutterSecureStorage.setMockInitialValues(
        savedCredentials(server.url, 'alice', 'secret'),
      );

      now = DateTime(2026, 11, 13, 12);
      appState = AppState(clock: () => now);
      addTearDown(appState.dispose);
      await appState.initialize();
      await pumpUntil(() => !appState.isLoading, reason: 'the first load');
      expect(appState.albumError, isNull);
      expect(appState.lastSyncTime, now);
    });

    tearDown(() async {
      await server.close();
      HttpOverrides.global = previousOverrides;
    });

    test('"Recently played" is synced after 20 minutes, not before', () async {
      expect(appState.albumListType, AlbumListType.recent);
      final lists = server.requestsTo('getAlbumList2').length;

      // Past the 5 minutes of "Recently added"
      now = now.add(const Duration(minutes: 19, seconds: 59));
      showAgain();
      expect(appState.syncStatus, SyncStatus.idle);

      now = now.add(const Duration(seconds: 1));
      showAgain();
      expect(appState.syncStatus, SyncStatus.syncing);
      await syncFinished();
      expect(appState.syncStatus, SyncStatus.success);
      // The cached list expired by the same clock, so it was fetched
      expect(server.requestsTo('getAlbumList2'), hasLength(lists + 1));
      expect(appState.lastSyncTime, now);
    });

    test('"Recently added" is checked again after 5 minutes', () async {
      await appState.setAlbumListType(AlbumListType.newest);
      expect(appState.albumError, isNull);
      final lists = server.requestsTo('getAlbumList2').length;
      final checks = server.requestsTo('getScanStatus').length;

      now = now.add(const Duration(minutes: 4, seconds: 59));
      showAgain();
      expect(appState.syncStatus, SyncStatus.idle);

      now = now.add(const Duration(seconds: 1));
      showAgain();
      expect(appState.syncStatus, SyncStatus.syncing);
      await syncFinished();
      expect(appState.syncStatus, SyncStatus.success);
      expect(appState.lastSyncTime, now);
      // The library is unchanged on the server: its version is checked, and
      // the cached list is kept
      expect(server.requestsTo('getScanStatus'), hasLength(checks + 1));
      expect(server.requestsTo('getAlbumList2'), hasLength(lists));
    });
  });
}
