import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/services/subsonic_api.dart';

import '../test_helpers/fake_subsonic_server.dart';

/// The artist list is large and only a library scan changes it, so once it
/// expires the server's scan status is checked before it's fetched again.
/// Against the fake server over real HTTPS.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSubsonicServer server;
  late HttpOverrides? previousOverrides;
  late DateTime now;
  late SubsonicApi api;

  setUp(() async {
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = FakeSubsonicServer.httpOverrides;
    server = FakeSubsonicServer();
    await server.start();
    now = DateTime(2026, 11, 16, 12);
    api = SubsonicApi(
      serverUrl: server.url,
      username: 'alice',
      password: 'secret',
      clock: () => now,
    );
    addTearDown(api.dispose);
  });

  tearDown(() async {
    await server.close();
    HttpOverrides.global = previousOverrides;
  });

  int fetches() => server.requestsTo('getArtists').length;

  test('an expired list is kept while the library is unscanned', () async {
    final artists = await api.getArtists();
    expect(fetches(), 1);

    now = now.add(const Duration(minutes: 16));
    expect(await api.getArtists(), artists);
    expect(fetches(), 1);
    expect(server.requestsTo('getScanStatus'), hasLength(2));
  });

  test('an expired list is fetched again after a scan', () async {
    await api.getArtists();

    server.lastScan = '2026-02-02T00:00:00Z';
    now = now.add(const Duration(minutes: 16));
    await api.getArtists();
    expect(fetches(), 2);
  });

  test(
    'an expired list is fetched when the server has no scan status',
    () async {
      await api.getArtists();

      server.failingEndpoints.add('getScanStatus');
      now = now.add(const Duration(minutes: 16));
      await api.getArtists();
      expect(fetches(), 2);
    },
  );
}
