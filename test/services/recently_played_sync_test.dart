import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/models/album_list_type.dart';
import 'package:voidweaver/services/app_state.dart';

import '../test_helpers/fake_subsonic_server.dart';
import '../test_helpers/saved_credentials.dart';

/// "Recently played" changes when a play is counted on the server, which the
/// app sees when its scrobble queue's submission goes through: the list is
/// fetched again then, rather than on a timer. Against the fake server over
/// real HTTPS.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSubsonicServer server;
  late HttpOverrides? previousOverrides;

  setUp(() async {
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = FakeSubsonicServer.httpOverrides;
    server = FakeSubsonicServer();
    await server.start();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('voidweaver_player'),
          (_) async => null,
        );
    // A play from an earlier session, sent when the app starts
    SharedPreferences.setMockInitialValues({
      'scrobble_queue': jsonEncode([
        {
          'songId': 's-1',
          'type': 'submission',
          'playedAt': DateTime(2026, 10, 30, 22).millisecondsSinceEpoch,
          'queuedAt': DateTime.now().millisecondsSinceEpoch,
        },
      ]),
    });
    FlutterSecureStorage.setMockInitialValues(
      savedCredentials(server.url, 'alice', 'secret'),
    );
  });

  tearDown(() async {
    await server.close();
    HttpOverrides.global = previousOverrides;
  });

  Future<AppState> loggedIn() async {
    final appState = AppState();
    addTearDown(appState.dispose);
    await appState.initialize();
    expect(appState.isConfigured, isTrue);
    return appState;
  }

  /// The album list requests made after the last scrobble
  int listsAfterScrobble() {
    final scrobble = server.requests.lastIndexWhere(
      (r) => r.endpoint == 'scrobble' && r.params['submission'] == 'true',
    );
    if (scrobble < 0) return 0;
    return server.requests
        .skip(scrobble)
        .where((r) => r.endpoint == 'getAlbumList2')
        .length;
  }

  test('a counted play fetches "Recently played" again', () async {
    final appState = await loggedIn();

    await _until(() => server.scrobbles.isNotEmpty, 'the play to arrive');
    await _until(() => listsAfterScrobble() >= 1, 'the list to be fetched');
    await _until(
      () => !appState.isLoading && appState.syncStatus != SyncStatus.syncing,
      'the fetches to finish',
    );

    // Once: the fetch that followed the play is the last one
    final lists = server.requestsTo('getAlbumList2').length;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.requestsTo('getAlbumList2'), hasLength(lists));
    expect(appState.albumError, isNull);
  });

  test('a play counted while the app is hidden is fetched once it is shown '
      'again', () async {
    final appState = await loggedIn();
    // Before the play goes out
    appState.setVisible(false);

    await _until(() => server.scrobbles.isNotEmpty, 'the play to arrive');
    await _until(() => !appState.isLoading, 'the first load to finish');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    // Nothing is fetched while hidden (the first load can come after the play)
    final hiddenLists = server.requestsTo('getAlbumList2').length;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.requestsTo('getAlbumList2'), hasLength(hiddenLists));

    // Not due by its age, but out of date
    appState.setVisible(true);
    expect(appState.syncStatus, SyncStatus.syncing);
    await _until(
      () => appState.syncStatus != SyncStatus.syncing,
      'the sync to finish',
    );
    expect(server.requestsTo('getAlbumList2').length, greaterThan(hiddenLists));
  });

  // A fetch that fails returns the cached list (see ApiCache). It's shown,
  // but must not count as up to date.
  test('a refresh that falls back to the cached list reports the failure '
      'and keeps the list', () async {
    final appState = await loggedIn();
    await _until(() => server.scrobbles.isNotEmpty, 'the play to arrive');
    await _until(() => listsAfterScrobble() >= 1, 'the list to be fetched');
    await _until(
      () => !appState.isLoading && appState.syncStatus != SyncStatus.syncing,
      'the fetches to finish',
    );
    final albums = appState.albums.map((a) => a.id).toList();
    expect(albums, isNotEmpty);
    final lastSync = appState.lastSyncTime;
    expect(lastSync, isNotNull);

    server.failingEndpoints.add('getAlbumList2');
    await appState.loadAlbums(forceRefresh: true);

    expect(appState.albums.map((a) => a.id), albums);
    // The pull-to-refresh shows it in a snack bar
    expect(appState.albumError, isNotNull);
    expect(appState.lastSyncTime, lastSync);
  });

  test('a sync that falls back to the cached list fails, and the next one '
      'fetches the list again', () async {
    final appState = await loggedIn();
    // Hidden, so the play counted after the first load started isn't
    // fetched: the list is out of date
    appState.setVisible(false);
    await _until(() => server.scrobbles.isNotEmpty, 'the play to arrive');
    await _until(() => !appState.isLoading, 'the first load to finish');
    final albums = appState.albums.map((a) => a.id).toList();
    expect(albums, isNotEmpty);
    final lastSync = appState.lastSyncTime;

    server.failingEndpoints.add('getAlbumList2');
    appState.setVisible(true);
    expect(appState.syncStatus, SyncStatus.syncing);
    await _until(
      () => appState.syncStatus != SyncStatus.syncing,
      'the sync to finish',
    );
    expect(appState.syncStatus, SyncStatus.error);
    expect(appState.albums.map((a) => a.id), albums);
    expect(appState.lastSyncTime, lastSync);

    // Still out of date, so it's due when shown again: before, the fallback
    // counted as the fetch, and the next one came only after 20 minutes
    server.failingEndpoints.clear();
    final lists = server.requestsTo('getAlbumList2').length;
    appState.setVisible(false);
    appState.setVisible(true);
    expect(appState.syncStatus, SyncStatus.syncing);
    await _until(
      () => appState.syncStatus != SyncStatus.syncing,
      'the second sync to finish',
    );
    expect(appState.syncStatus, SyncStatus.success);
    expect(server.requestsTo('getAlbumList2'), hasLength(lists + 1));
    expect(appState.lastSyncTime, isNot(lastSync));
    expect(appState.albumError, isNull);
  });

  test('a play does not fetch the list of "Recently added"', () async {
    final appState = await loggedIn();
    await appState.setAlbumListType(AlbumListType.newest);
    final lists = server.requestsTo('getAlbumList2').length;

    await _until(() => server.scrobbles.isNotEmpty, 'the play to arrive');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // Only the loads of the orders shown: that of the other order, if it
    // was still running, but none for the play
    expect(
      server.requestsTo('getAlbumList2').length,
      lessThanOrEqualTo(lists + 1),
    );
    expect(appState.albumListType, AlbumListType.newest);
  });
}

Future<void> _until(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting: $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
