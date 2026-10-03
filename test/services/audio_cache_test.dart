import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voidweaver/services/audio_cache.dart';

void main() {
  group('AudioCache', () {
    late Directory dir;
    late int requestCount;

    MockClient audioClient({
      int status = 200,
      String contentType = 'audio/mpeg',
      List<int> body = const [1, 2, 3, 4],
    }) {
      return MockClient((request) async {
        requestCount++;
        return http.Response.bytes(body, status,
            headers: {'content-type': contentType});
      });
    }

    AudioCache createCache(http.Client client,
            {int maxBytes = AudioCache.defaultMaxBytes,
            String namespace = ''}) =>
        AudioCache(
          client: client,
          maxBytes: maxBytes,
          namespace: namespace,
          directoryProvider: () async => dir,
        );

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('audio_cache_test');
      requestCount = 0;
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('downloads a song and serves it from disk', () async {
      final cache = createCache(audioClient());

      expect(cache.getCachedFile('song1'), isNull);
      final file = await cache.prefetch('song1', 'https://x/stream?id=song1');

      expect(file, isNotNull);
      expect(file!.path, endsWith('.mp3'));
      expect(await file.readAsBytes(), [1, 2, 3, 4]);
      expect(cache.getCachedFile('song1')?.path, file.path);
      expect(cache.isCached('song1'), isTrue);

      // Already cached, so no second download
      await cache.prefetch('song1', 'https://x/stream?id=song1');
      expect(requestCount, 1);
    });

    test('deduplicates concurrent downloads of the same song', () async {
      final cache = createCache(audioClient());

      await Future.wait([
        cache.prefetch('song1', 'https://x/a'),
        cache.prefetch('song1', 'https://x/b'),
      ]);

      expect(requestCount, 1);
    });

    test('does not cache failed or error-document responses', () async {
      final failing = createCache(audioClient(status: 500));
      expect(await failing.prefetch('song1', 'https://x/s'), isNull);
      expect(failing.isCached('song1'), isFalse);

      final xmlError = createCache(audioClient(contentType: 'text/xml'));
      expect(await xmlError.prefetch('song2', 'https://x/s'), isNull);
      expect(xmlError.isCached('song2'), isFalse);

      // No partial files left behind
      expect(await dir.list().toList(), isEmpty);
    });

    test('restores its index from disk and removes partial files', () async {
      final cache = createCache(audioClient());
      await cache.prefetch('song1', 'https://x/s');
      await File('${dir.path}/leftover.part').writeAsBytes([0]);

      final restarted = createCache(audioClient());
      await restarted.initialize();

      expect(restarted.getCachedFile('song1'), isNotNull);
      expect(File('${dir.path}/leftover.part').existsSync(), isFalse);
    });

    test('evicts least recently used files over the size limit', () async {
      final cache =
          createCache(audioClient(body: List.filled(10, 0)), maxBytes: 25);

      await cache.prefetch('old', 'https://x/1');
      await cache.prefetch('middle', 'https://x/2');
      // Make 'old' clearly the least recently used
      cache.getCachedFile('old')!.setLastModifiedSync(
          DateTime.now().subtract(const Duration(hours: 1)));
      await cache.prefetch('new', 'https://x/3');

      expect(cache.isCached('old'), isFalse);
      expect(cache.isCached('middle'), isTrue);
      expect(cache.isCached('new'), isTrue);
    });

    test('keeps songs from different namespaces apart', () async {
      final serverA = createCache(audioClient(), namespace: 'https://a');
      await serverA.prefetch('1', 'https://a/s');

      final serverB = createCache(audioClient(), namespace: 'https://b');
      await serverB.initialize();

      expect(serverB.isCached('1'), isFalse);
    });

    test('clear removes all cached files', () async {
      final cache = createCache(audioClient());
      await cache.prefetch('song1', 'https://x/s');

      await cache.clear();

      expect(cache.isCached('song1'), isFalse);
      expect(await dir.list().toList(), isEmpty);
    });
  });
}
