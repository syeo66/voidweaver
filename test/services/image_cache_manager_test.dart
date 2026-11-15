import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show
        CacheManager,
        Config,
        FileService,
        FileSystem,
        FileServiceResponse,
        NonStoringObjectProvider;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/services/image_cache_manager.dart';
import 'package:voidweaver/services/subsonic_api.dart';

import '../test_helpers/fake_subsonic_server.dart';

/// Never has a file and fails every download, so no platform plugin is needed
class _OfflineFileService extends FileService {
  @override
  Future<FileServiceResponse> get(String url, {Map<String, String>? headers}) =>
      Future.error(const SocketException('offline'));
}

/// Never asked for a file: nothing is downloaded
class _NoFileSystem implements FileSystem {
  @override
  Future<Never> createFile(String name) => Future.error(StateError(name));
}

CacheManager _offlineManager() => CacheManager(
  Config(
    'test',
    repo: NonStoringObjectProvider(),
    fileSystem: _NoFileSystem(),
    fileService: _OfflineFileService(),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => ImageCacheManager.cacheManager = null);

  group('ImageCacheManager.coverArtSizeFor', () {
    test('picks the smallest size covering the box in physical pixels', () {
      expect(ImageCacheManager.coverArtSizeFor(50, 2.625), 150);
      expect(ImageCacheManager.coverArtSizeFor(56, 3), 300);
      // The now-playing art on a Pixel 8
      expect(ImageCacheManager.coverArtSizeFor(200, 2.625), 600);
      expect(ImageCacheManager.coverArtSizeFor(200, 1), 300);
    });

    test('takes the largest size for a box bigger than all sizes', () {
      expect(ImageCacheManager.coverArtSizeFor(800, 3), 1200);
    });

    test('takes a medium size for an unbounded box', () {
      expect(ImageCacheManager.coverArtSizeFor(null, 3), 600);
      expect(ImageCacheManager.coverArtSizeFor(double.infinity, 3), 600);
    });
  });

  group('ImageCacheManager cache', () {
    test('keeps far more than the default 200 images', () {
      // Scrolling through a library's album grid must not push covers out
      expect(ImageCacheManager.maxCachedImages, greaterThan(1000));
      expect(
        ImageCacheManager.cachedImageLifetime,
        greaterThan(const Duration(days: 30)),
      );
    });

    test('cover art providers use it', () {
      final manager = _offlineManager();
      ImageCacheManager.cacheManager = manager;
      final api = SubsonicApi(
        serverUrl: 'https://music.example.com',
        username: 'testuser',
        password: 'testpass',
      );
      addTearDown(api.dispose);

      final provider = ImageCacheManager.coverArtProvider(
        api,
        'al-1',
      ) as CachedNetworkImageProvider;

      expect(provider.cacheManager, same(manager));
    });
  });

  group('ImageCacheManager.buildCoverArt', () {
    late SubsonicApi api;

    late CacheManager manager;

    setUp(() {
      manager = _offlineManager();
      ImageCacheManager.cacheManager = manager;
      api = SubsonicApi(
        serverUrl: 'https://music.example.com',
        username: 'testuser',
        password: 'testpass',
      );
    });

    tearDown(() => api.dispose());

    Future<CachedNetworkImage> pumpCover(
      WidgetTester tester,
      Widget cover, {
      double pixelRatio = 3,
    }) async {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(devicePixelRatio: pixelRatio),
          child: Center(child: cover),
        ),
      );
      return tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
    }

    testWidgets('fetches the size of the given width and height', (
      tester,
    ) async {
      final image = await pumpCover(
        tester,
        ImageCacheManager.buildCoverArt(
          api: api,
          coverArtId: 'al-1',
          width: 50,
          height: 50,
        ),
      );

      expect(Uri.parse(image.imageUrl).queryParameters['size'], '150');
      expect(image.cacheKey, api.coverArtCacheKey('al-1', size: 150));
      expect(image.cacheManager, same(manager));
    });

    testWidgets('fetches the size of the box it is laid out in', (
      tester,
    ) async {
      final image = await pumpCover(
        tester,
        SizedBox(
          width: 200,
          height: 200,
          child: ImageCacheManager.buildCoverArt(api: api, coverArtId: 'al-1'),
        ),
      );

      expect(Uri.parse(image.imageUrl).queryParameters['size'], '600');
      expect(image.cacheKey, api.coverArtCacheKey('al-1', size: 600));
    });
  });

  group('CoverArtFileService', () {
    late FakeSubsonicServer server;
    late HttpOverrides? previousOverrides;

    setUp(() async {
      // After the test binding, which installs overrides that fail every
      // request
      previousOverrides = HttpOverrides.current;
      HttpOverrides.global = FakeSubsonicServer.httpOverrides;
      server = FakeSubsonicServer();
      await server.start();
    });

    tearDown(() async {
      await server.close();
      HttpOverrides.global = previousOverrides;
    });

    SubsonicApi login({String password = 'secret'}) {
      final api = SubsonicApi(
        serverUrl: server.url,
        username: 'alice',
        password: password,
        appVersion: '1.3.0',
      );
      addTearDown(api.dispose);
      return api;
    }

    String rejection() =>
        '<subsonic-response status="failed">'
        '<error code="40" message="Wrong username or password"/>'
        '</subsonic-response>';

    test('fetches a cover with the API\'s user agent', () async {
      final api = login();
      final response = await CoverArtFileService(() => api)
          .get(api.getCoverArtUrl('al-1'));
      await response.content.drain<void>();

      expect(response.statusCode, 200);
      expect(response.fileExtension, '.png');
      expect(
        server.requestsTo('getCoverArt').single.userAgent,
        'voidweaver/1.3.0',
      );
    });

    test('a cover refused for the credentials is an error, and rejects '
        'them', () async {
      // The server answers with HTTP 200 and XML, as Navidrome does
      final api = login(password: 'old');

      await expectLater(
        CoverArtFileService(() => api).get(api.getCoverArtUrl('al-1')),
        throwsA(isA<HttpException>()),
      );
      expect(api.credentialsRejected.value, isTrue);
    });

    test('fetches nothing while the credentials are rejected', () async {
      final api = login();
      api.checkRefusal(rejection());

      await expectLater(
        CoverArtFileService(() => api).get(api.getCoverArtUrl('al-1')),
        throwsA(isA<HttpException>()),
      );
      expect(server.requestsTo('getCoverArt'), isEmpty);
    });

    test(
      'another document is an error, leaving the credentials alone',
      () async {
        final api = login();
        final service = CoverArtFileService(
          () => api,
          httpClient: MockClient(
            (request) async => http.Response(
              '<html>Maintenance</html>',
              200,
              headers: {'content-type': 'text/html'},
            ),
          ),
        );

        await expectLater(
          service.get(api.getCoverArtUrl('al-1')),
          throwsA(isA<HttpException>()),
        );
        expect(api.credentialsRejected.value, isFalse);
      },
    );

    test('the cache manager stores no file for a refused cover', () async {
      final api = login();
      final manager = CacheManager(
        Config(
          'test',
          repo: NonStoringObjectProvider(),
          // Throws if the manager tried to store a file
          fileSystem: _NoFileSystem(),
          fileService: CoverArtFileService(
            () => api,
            httpClient: MockClient(
              (request) async => http.Response(
                rejection(),
                200,
                headers: {'content-type': 'application/xml'},
              ),
            ),
          ),
        ),
      );

      await expectLater(
        manager.downloadFile(api.getCoverArtUrl('al-1')),
        throwsA(isA<HttpException>()),
      );
      expect(api.credentialsRejected.value, isTrue);
    });

    test('tells documents from images', () {
      for (final type in [
        'application/xml',
        'text/xml; charset=utf-8',
        'application/json',
        'text/html',
        'text/plain',
      ]) {
        expect(CoverArtFileService.isDocument(type), isTrue, reason: type);
      }
      for (final type in [
        'image/jpeg',
        'image/png',
        'image/svg+xml; charset=utf-8',
        'application/octet-stream',
      ]) {
        expect(CoverArtFileService.isDocument(type), isFalse, reason: type);
      }
    });
  });
}
