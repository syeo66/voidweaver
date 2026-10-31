import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/app_state.dart';
import 'package:voidweaver/services/subsonic_api.dart';

import '../test_helpers/fake_subsonic_server.dart';

/// A password changed on the server: the API notices the rejected
/// credentials, and AppState.updatePassword() logs in again without losing
/// pending plays. Against the fake server over real HTTPS.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSubsonicServer server;
  late HttpOverrides? previousOverrides;

  setUp(() async {
    // After the test binding, which installs overrides that fail every request
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = FakeSubsonicServer.httpOverrides;
    server = FakeSubsonicServer();
    await server.start();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('voidweaver_player'), (_) async => null);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    await server.close();
    HttpOverrides.global = previousOverrides;
  });

  SubsonicApi api({String password = 'secret'}) {
    final api = SubsonicApi(
        serverUrl: server.url, username: 'alice', password: password);
    addTearDown(api.dispose);
    return api;
  }

  group('SubsonicApi.credentialsRejected', () {
    test('is set by an auth error and cleared by the next answer', () async {
      final client = api();
      await client.ping();
      expect(client.credentialsRejected.value, isFalse);

      server.password = 'changed';
      await expectLater(
          client.getRandomSongs(), throwsA(isA<SubsonicException>()));
      expect(client.credentialsRejected.value, isTrue);

      server.password = 'secret';
      expect(await client.getRandomSongs(5), hasLength(5));
      expect(client.credentialsRejected.value, isFalse);
    });

    test('is set by requests parsed on a background isolate', () async {
      final client = api(password: 'wrong');
      await expectLater(
          client.getArtists(),
          throwsA(isA<SubsonicException>()
              .having((e) => e.isAuthError, 'isAuthError', isTrue)));
      expect(client.credentialsRejected.value, isTrue);
    });

    test('is not set by other server errors', () async {
      final client = api();
      await expectLater(
          client.getAlbum('missing'), throwsA(isA<SubsonicException>()));
      expect(client.credentialsRejected.value, isFalse);
    });

    test('is not changed by requests that do not reach the server', () async {
      final client = api(password: 'wrong');
      await expectLater(client.ping(), throwsA(isA<SubsonicException>()));
      await server.close();
      await expectLater(client.ping(), throwsA(anything));
      expect(client.credentialsRejected.value, isTrue);
    });
  });

  test('the fake server serves albums, songs and scrobbles', () async {
    final client = api();
    final albums = await client.getAlbumList();
    expect(albums.map((a) => a.name),
        ['First Light', 'Second Wind', 'Third Rail']);
    final album = await client.getAlbum(albums.first.id);
    expect(album.songs.map((s) => s.title), ['Dawn', 'Noon', 'Dusk']);
    expect(album.songs.first.duration, 4);

    await client.scrobbleSubmission('s-1', playedAt: DateTime(2026));
    expect(server.scrobbles.single.songId, 's-1');
    expect(server.scrobbles.single.submission, isTrue);

    // The stream is a WAV, also in ranges
    final http = HttpClient();
    addTearDown(http.close);
    final request = await http.getUrl(Uri.parse(client.getStreamUrl('s-1')));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-3');
    final response = await request.close();
    expect(response.statusCode, HttpStatus.partialContent);
    expect(ascii.decode(await response.expand((b) => b).toList()), 'RIFF');
  });

  group('AppState', () {
    /// Logged in with saved credentials ('secret'), like at startup, so
    /// they aren't checked
    Future<AppState> loggedIn() async {
      FlutterSecureStorage.setMockInitialValues({
        'server_url': server.url,
        'username': 'alice',
        'password': 'secret',
      });
      final appState = AppState();
      addTearDown(appState.dispose);
      await appState.initialize();
      expect(appState.isConfigured, isTrue);
      return appState;
    }

    test('reports rejected credentials and updates the password', () async {
      final appState = await loggedIn();
      await appState.loadAlbums();
      expect(appState.credentialsRejected, isFalse);

      server.password = 'changed';
      var notified = false;
      appState.addListener(() => notified = true);
      await appState.loadAlbums(forceRefresh: true);
      expect(appState.credentialsRejected, isTrue);
      expect(notified, isTrue);

      // A wrong one changes nothing
      final api = appState.api;
      await expectLater(appState.updatePassword('still wrong'),
          throwsA(isA<SubsonicException>()));
      expect(appState.isConfigured, isTrue);
      expect(appState.api, same(api));
      expect(appState.credentialsRejected, isTrue);

      await appState.updatePassword('changed');
      expect(appState.isConfigured, isTrue);
      expect(appState.api, isNot(same(api)));
      expect(appState.credentialsRejected, isFalse);
      expect(
          await const FlutterSecureStorage().read(key: 'password'), 'changed');
      expect(await const FlutterSecureStorage().read(key: 'server_url'),
          server.url);
    });

    test('keeps pending plays, which are sent with the new password', () async {
      server.password = 'changed';
      final playedAt = DateTime(2026, 10, 30, 22);
      SharedPreferences.setMockInitialValues({
        'scrobble_queue': jsonEncode([
          {
            'songId': 's-2',
            'type': 'submission',
            'playedAt': playedAt.millisecondsSinceEpoch,
            'queuedAt': DateTime.now().millisecondsSinceEpoch,
          }
        ]),
      });
      final appState = await loggedIn();
      // The queue tries to send the play on startup, which is refused
      await _until(() => appState.credentialsRejected,
          'rejected (requests: ${server.requests.map((r) => r.endpoint)})');
      expect(appState.pendingScrobbles, 1);
      expect(server.scrobbles, isEmpty);

      await appState.updatePassword('changed');
      await _until(() => server.scrobbles.isNotEmpty, 'the play to arrive');
      expect(server.scrobbles.single.songId, 's-2');
      expect(server.scrobbles.single.time, playedAt);
      await _until(() => appState.pendingScrobbles == 0, 'an empty queue');
    });
  });
}

Future<void> _until(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting: $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
