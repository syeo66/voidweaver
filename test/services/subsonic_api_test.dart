import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/network_config.dart';
import 'package:voidweaver/services/subsonic_api.dart';

void main() {
  // Initialize Flutter test binding
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SubsonicApi HTTPS Enforcement', () {
    test('should accept HTTPS URLs', () async {
      // Mock the SharedPreferences plugin for testing
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/shared_preferences'),
              (MethodCall methodCall) async {
        return <String, dynamic>{};
      });

      expect(
        () => SubsonicApi(
          serverUrl: 'https://demo.navidrome.org',
          username: 'testuser',
          password: 'testpass',
        ),
        returnsNormally,
      );
    });

    test('should reject HTTP URLs', () {
      expect(
        () => SubsonicApi(
          serverUrl: 'http://demo.navidrome.org',
          username: 'testuser',
          password: 'testpass',
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('Server URL must use HTTPS protocol for security'),
        )),
      );
    });

    test('should reject invalid URLs', () {
      expect(
        () => SubsonicApi(
          serverUrl: 'not-a-url',
          username: 'testuser',
          password: 'testpass',
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('Server URL must use HTTPS protocol for security'),
        )),
      );
    });

    test('should reject FTP URLs', () {
      expect(
        () => SubsonicApi(
          serverUrl: 'ftp://example.com',
          username: 'testuser',
          password: 'testpass',
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('Server URL must use HTTPS protocol for security'),
        )),
      );
    });

    test('should dispose properly after creation', () async {
      // Mock the SharedPreferences plugin for testing
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/shared_preferences'),
              (MethodCall methodCall) async {
        return <String, dynamic>{};
      });

      final api = SubsonicApi(
        serverUrl: 'https://demo.navidrome.org',
        username: 'testuser',
        password: 'testpass',
      );

      // Should not throw when disposing
      expect(() => api.dispose(), returnsNormally);
    });
  });

  group('SubsonicApi request errors', () {
    test('keep their type', () async {
      await HttpOverrides.runZoned(() async {
        final api = SubsonicApi(
          serverUrl: 'https://music.example',
          username: 'user',
          password: 'pass',
        );
        addTearDown(api.dispose);
        await expectLater(api.ping(), throwsA(isA<StateError>()));
      }, createHttpClient: (_) => _ThrowingHttpClient());
    });
  });

  group('SubsonicApi network config', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('uses the config it was created with', () {
      final api = SubsonicApi(
        serverUrl: 'https://demo.navidrome.org',
        username: 'testuser',
        password: 'testpass',
        networkConfig: NetworkConfig.slowConfig,
      );
      addTearDown(api.dispose);

      expect(api.networkConfig, NetworkConfig.slowConfig);
    });

    test('applies a changed config and stays usable', () {
      final api = SubsonicApi(
        serverUrl: 'https://demo.navidrome.org',
        username: 'testuser',
        password: 'testpass',
      );

      api.networkConfig = NetworkConfig.fastConfig;

      expect(api.networkConfig, NetworkConfig.fastConfig);
      // The replaced client is closed once; disposing closes the new one
      expect(api.dispose, returnsNormally);
    });
  });

  group('SubsonicApi.coverArtCacheKey', () {
    SubsonicApi apiFor(String serverUrl) {
      final api = SubsonicApi(
        serverUrl: serverUrl,
        username: 'testuser',
        password: 'testpass',
      );
      addTearDown(api.dispose);
      return api;
    }

    test('is stable although the URL changes with every request', () {
      final api = apiFor('https://a.example.com');

      expect(api.getCoverArtUrl('al-1'), isNot(api.getCoverArtUrl('al-1')));
      expect(api.coverArtCacheKey('al-1'), api.coverArtCacheKey('al-1'));
    });

    test('differs between servers for the same id', () {
      expect(apiFor('https://a.example.com').coverArtCacheKey('al-1'),
          isNot(apiFor('https://b.example.com').coverArtCacheKey('al-1')));
    });

    test('differs between sizes, which the URL requests', () {
      final api = apiFor('https://a.example.com');

      expect(api.coverArtCacheKey('al-1', size: 150),
          isNot(api.coverArtCacheKey('al-1', size: 600)));
      expect(
          Uri.parse(api.getCoverArtUrl('al-1', size: 600))
              .queryParameters['size'],
          '600');
    });
  });

  group('SubsonicApi.libraryVersionFrom', () {
    String? versionOf(String scanStatus) =>
        SubsonicApi.libraryVersionFrom(SubsonicApi.parseResponse(
            '<subsonic-response xmlns="http://subsonic.org/restapi" '
            'status="ok" version="1.16.1">$scanStatus</subsonic-response>'));

    test('combines the last scan and the song count', () {
      expect(
          versionOf('<scanStatus scanning="false" count="1234" '
              'folderCount="12" lastScan="2026-10-19T08:00:00Z"/>'),
          '2026-10-19T08:00:00Z/1234');
    });

    test('is unknown while scanning', () {
      expect(
          versionOf('<scanStatus scanning="true" count="1000" '
              'lastScan="2026-10-19T08:00:00Z"/>'),
          isNull);
    });

    test('is unknown without the last scan', () {
      expect(versionOf('<scanStatus scanning="false" count="1234"/>'), isNull);
    });
  });

  group('SubsonicApi.parseResponse', () {
    test('returns the document for an ok response', () {
      final doc = SubsonicApi.parseResponse(
          '<subsonic-response xmlns="http://subsonic.org/restapi" '
          'status="ok" version="1.16.1"/>');
      expect(doc.rootElement.getAttribute('status'), 'ok');
    });

    test('throws the server error for a failed response', () {
      expect(
        () => SubsonicApi.parseResponse(
            '<subsonic-response xmlns="http://subsonic.org/restapi" '
            'status="failed" version="1.16.1">'
            '<error code="40" message="Wrong username or password"/>'
            '</subsonic-response>'),
        throwsA(isA<SubsonicException>()
            .having((e) => e.code, 'code', 40)
            .having((e) => e.isAuthError, 'isAuthError', isTrue)
            .having(
                (e) => e.toString(), 'message', 'Wrong username or password')),
      );
    });

    test('throws for a failed response without an error element', () {
      expect(
        () => SubsonicApi.parseResponse(
            '<subsonic-response status="failed" version="1.16.1"/>'),
        throwsA(isA<SubsonicException>().having((e) => e.code, 'code', null)),
      );
    });

    test('does not treat other errors as auth errors', () {
      expect(const SubsonicException(70, 'Not found').isAuthError, isFalse);
      expect(const SubsonicException(null, 'Unknown').isAuthError, isFalse);
    });
  });

  group('SubsonicApi.parseInBackground', () {
    Uint8List bytes(String body) => Uint8List.fromList(utf8.encode(body));

    test('parses albums on another isolate', () async {
      final albums = await SubsonicApi.parseInBackground(
          bytes('<subsonic-response status="ok"><albumList2>'
              '<album id="1" name="Müde" artist="A" songCount="3"/>'
              '<album id="2" name="Second" artist="B"/>'
              '</albumList2></subsonic-response>'),
          SubsonicApi.albumsFromXml);

      expect(albums.map((a) => a.name), ['Müde', 'Second']);
      expect(albums.first.songCount, 3);
    });

    test('keeps the type and code of a server error', () async {
      await expectLater(
        SubsonicApi.parseInBackground(
            bytes('<subsonic-response status="failed">'
                '<error code="40" message="Wrong username or password"/>'
                '</subsonic-response>'),
            SubsonicApi.albumsFromXml),
        throwsA(isA<SubsonicException>()
            .having((e) => e.isAuthError, 'isAuthError', isTrue)),
      );
    });
  });

  group('SubsonicApi.fetchAllAlbumPages', () {
    List<Album> albums(int from, int count) => [
          for (var i = from; i < from + count; i++)
            Album(id: 'a$i', name: 'Album $i', artist: 'Artist', songs: [])
        ];

    test('requests pages until one comes back short', () async {
      final offsets = <int>[];
      final result = await SubsonicApi.fetchAllAlbumPages((offset) async {
        offsets.add(offset);
        return albums(offset, offset < 6 ? 3 : 1);
      }, pageSize: 3);

      expect(offsets, [0, 3, 6]);
      expect(result.map((a) => a.id), [for (var i = 0; i < 7; i++) 'a$i']);
    });

    test('stops when the server ignores the offset', () async {
      var requests = 0;
      final result = await SubsonicApi.fetchAllAlbumPages((offset) async {
        requests++;
        return albums(0, 3);
      }, pageSize: 3);

      expect(requests, 2);
      expect(result, hasLength(3));
    });

    test('drops an album seen again after the list shifted', () async {
      final result = await SubsonicApi.fetchAllAlbumPages((offset) async {
        // A new album at the top pushed a2 onto the second page
        return offset == 0 ? albums(0, 3) : albums(2, 2);
      }, pageSize: 3);

      expect(result.map((a) => a.id), ['a0', 'a1', 'a2', 'a3']);
    });
  });

  group('Song.copyWith', () {
    test('keeps every field it is not given', () {
      final song = Song(
        id: '1',
        title: 'Title',
        artist: 'Artist',
        album: 'Album',
        albumId: 'al1',
        coverArt: 'cover',
        duration: 200,
        track: 3,
        contentType: 'audio/flac',
        suffix: 'flac',
        replayGainTrackPeak: 0.9,
      );

      expect(
          song.copyWith(replayGainTrackGain: -6.5),
          Song(
            id: '1',
            title: 'Title',
            artist: 'Artist',
            album: 'Album',
            albumId: 'al1',
            coverArt: 'cover',
            duration: 200,
            track: 3,
            contentType: 'audio/flac',
            suffix: 'flac',
            replayGainTrackGain: -6.5,
            replayGainTrackPeak: 0.9,
          ));
    });
  });
}

/// An HTTP client whose requests fail with an error the API doesn't expect.
class _ThrowingHttpClient implements HttpClient {
  @override
  Duration? connectionTimeout;
  @override
  int? maxConnectionsPerHost;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      Future.error(StateError('unexpected'));

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
