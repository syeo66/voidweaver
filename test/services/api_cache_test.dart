import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/api_cache.dart';
import 'package:voidweaver/services/subsonic_api.dart';

void main() {
  group('API Cache Tests', () {
    late ApiCache cache;
    late Directory directory;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      directory = await Directory.systemTemp.createTemp('api_cache_test');
      cache = ApiCache.forTesting(directory: directory);
      await cache.initialize();
    });

    tearDown(() => directory.delete(recursive: true));

    test('should cache and retrieve values', () async {
      const endpoint = 'test_endpoint';
      const params = {'param1': 'value1', 'param2': 'value2'};
      const expectedResult = 'test_result';

      var callCount = 0;
      final result = await cache.getOrFetch<String>(
        endpoint,
        params,
        () async {
          callCount++;
          return expectedResult;
        },
        cacheDuration: const Duration(seconds: 10),
      );

      expect(result, expectedResult);
      expect(callCount, 1);

      // Second call should use cache
      final cachedResult = await cache.getOrFetch<String>(
        endpoint,
        params,
        () async {
          callCount++;
          return 'should_not_be_called';
        },
        cacheDuration: const Duration(seconds: 10),
      );

      expect(cachedResult, expectedResult);
      expect(callCount, 1); // Should not increase
    });

    test('should deduplicate concurrent requests', () async {
      const endpoint = 'test_endpoint';
      const params = {'param1': 'value1'};
      const expectedResult = 'test_result';

      var callCount = 0;
      Future<String> makeRequest() {
        return cache.getOrFetch<String>(
          endpoint,
          params,
          () async {
            callCount++;
            await Future.delayed(const Duration(milliseconds: 50));
            return expectedResult;
          },
          cacheDuration: const Duration(seconds: 10),
        );
      }

      // Start multiple concurrent requests
      final futures = List.generate(5, (_) => makeRequest());
      final results = await Future.wait(futures);

      // All should return the same result
      expect(results, List.filled(5, expectedResult));
      // But fetcher should only be called once
      expect(callCount, 1);
    });

    test('should handle cache expiration', () async {
      const endpoint = 'test_endpoint';
      const params = {'param1': 'value1'};

      var callCount = 0;
      String fetchData() {
        callCount++;
        return 'result_$callCount';
      }

      // First call
      final result1 = await cache.getOrFetch<String>(
        endpoint,
        params,
        () async => fetchData(),
        cacheDuration: const Duration(milliseconds: 50),
      );

      expect(result1, 'result_1');
      expect(callCount, 1);

      // Wait for cache to expire
      await Future.delayed(const Duration(milliseconds: 100));

      // Second call should fetch new data
      final result2 = await cache.getOrFetch<String>(
        endpoint,
        params,
        () async => fetchData(),
        cacheDuration: const Duration(milliseconds: 50),
      );

      expect(result2, 'result_2');
      expect(callCount, 2);
    });

    test('should generate consistent cache keys', () async {
      const endpoint = 'test_endpoint';
      const params1 = {'b': '2', 'a': '1'};
      const params2 = {'a': '1', 'b': '2'};

      var callCount = 0;
      Future<String> fetchData() async {
        callCount++;
        return 'result_$callCount';
      }

      // First call with params1
      final result1 = await cache.getOrFetch<String>(
        endpoint,
        params1,
        fetchData,
        cacheDuration: const Duration(seconds: 10),
      );

      // Second call with params2 (same params, different order)
      final result2 = await cache.getOrFetch<String>(
        endpoint,
        params2,
        fetchData,
        cacheDuration: const Duration(seconds: 10),
      );

      expect(result1, result2);
      expect(callCount, 1); // Should use cache
    });

    test('should clear cache entries', () async {
      const endpoint = 'test_endpoint';
      const params = {'param1': 'value1'};

      var callCount = 0;
      Future<String> fetchData() async {
        callCount++;
        return 'result_$callCount';
      }

      // First call
      await cache.getOrFetch<String>(
        endpoint,
        params,
        fetchData,
        cacheDuration: const Duration(seconds: 10),
      );

      expect(callCount, 1);

      // Clear cache
      cache.clearEntry(endpoint, params);

      // Second call should fetch new data
      await cache.getOrFetch<String>(
        endpoint,
        params,
        fetchData,
        cacheDuration: const Duration(seconds: 10),
      );

      expect(callCount, 2);
    });

    test('should persist typed data across instances using codecs', () async {
      final albums = [
        Album(id: 'a1', name: 'First', artist: 'Artist', songs: [
          Song(id: 's1', title: 'Song', artist: 'Artist', album: 'First'),
        ]),
      ];
      Object? toJson(List<Album> data) => data.map((a) => a.toJson()).toList();
      List<Album> fromJson(dynamic json) => (json as List<dynamic>)
          .map((a) => Album.fromJson(a as Map<String, dynamic>))
          .toList();

      await cache.getOrFetch<List<Album>>(
          'getAlbumList2', null, () async => albums,
          usePersistentCache: true, toJson: toJson, fromJson: fromJson);

      // A fresh instance (e.g. after app restart) has an empty memory cache
      final restarted = ApiCache.forTesting(directory: directory);
      await restarted.initialize();
      var fetched = false;
      final result = await restarted
          .getOrFetch<List<Album>>('getAlbumList2', null, () async {
        fetched = true;
        return <Album>[];
      }, usePersistentCache: true, toJson: toJson, fromJson: fromJson);

      expect(fetched, isFalse);
      expect(result, albums);
    });

    test('persists entries too large to decode on the UI isolate', () async {
      final large = 'x' * (128 * 1024);
      await cache.getOrFetch<List<String>>('large', null, () async => [large],
          usePersistentCache: true,
          fromJson: (json) => (json as List<dynamic>).cast<String>());

      final restarted = ApiCache.forTesting(directory: directory);
      await restarted.initialize();
      final result = await restarted.getOrFetch<List<String>>(
          'large', null, () async => fail('read from the file'),
          usePersistentCache: true,
          fromJson: (json) => (json as List<dynamic>).cast<String>());

      expect(result, [large]);
    });

    test('clearAll removes persisted entries before the cache was used',
        () async {
      await cache.getOrFetch<String>('endpoint', null, () async => 'saved',
          usePersistentCache: true);

      // Not initialized and nothing loaded, as right after a restart
      final restarted = ApiCache.forTesting(directory: directory);
      await restarted.clearAll();

      expect(directory.listSync(), isEmpty);
    });

    test('moves entries from SharedPreferences to files, except searches',
        () async {
      String entry(String data) => jsonEncode({
            'data': data,
            'expiresAt': DateTime.now()
                .add(const Duration(minutes: 5))
                .toIso8601String(),
            'key': 'unused',
          });
      SharedPreferences.setMockInitialValues({
        'cache_getArtists?': entry('artists'),
        'cache_search3?query=x': entry('search'),
        'themeMode': 1,
      });
      final fresh = await Directory.systemTemp.createTemp('api_cache_test');
      addTearDown(() => fresh.delete(recursive: true));

      final migrated = ApiCache.forTesting(directory: fresh);
      final result = await migrated.getOrFetch<String>(
          'getArtists', null, () async => 'fetched',
          usePersistentCache: true);

      expect(result, 'artists');
      expect(fresh.listSync(), hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {'themeMode'});
    });

    test('a corrupted file is dropped and fetched again', () async {
      await cache.getOrFetch<String>('endpoint', null, () async => 'saved',
          usePersistentCache: true);
      final file = directory.listSync().single as File;
      file.writeAsStringSync('{not json');

      final restarted = ApiCache.forTesting(directory: directory);
      final result = await restarted.getOrFetch<String>(
          'endpoint', null, () async => 'fetched',
          usePersistentCache: true);

      expect(result, 'fetched');
    });

    test('works in memory when the storage is unavailable', () async {
      final memoryOnly = ApiCache.forTesting();
      await memoryOnly.getOrFetch<String>('endpoint', null, () async => 'a',
          usePersistentCache: true);
      final result = await memoryOnly.getOrFetch<String>(
          'endpoint', null, () async => 'b',
          usePersistentCache: true);

      expect(result, 'a');
    });

    test('should serve stale memory data when fetch fails', () async {
      await cache.getOrFetch<String>('endpoint', null, () async => 'fresh',
          cacheDuration: Duration.zero);
      await Future.delayed(const Duration(milliseconds: 5));

      final result = await cache.getOrFetch<String>(
          'endpoint', null, () async => throw Exception('offline'));

      expect(result, 'fresh');
    });

    test('should serve stale persistent data when fetch fails after restart',
        () async {
      await cache.getOrFetch<String>('endpoint', null, () async => 'saved',
          cacheDuration: Duration.zero, usePersistentCache: true);
      await Future.delayed(const Duration(milliseconds: 5));

      final restarted = ApiCache.forTesting(directory: directory);
      await restarted.initialize();
      final result = await restarted.getOrFetch<String>(
          'endpoint', null, () async => throw Exception('offline'),
          usePersistentCache: true);

      expect(result, 'saved');
    });

    test('should fetch despite a valid entry with forceRefresh', () async {
      await cache.getOrFetch<String>('endpoint', null, () async => 'old',
          cacheDuration: const Duration(minutes: 3), usePersistentCache: true);

      final result = await cache.getOrFetch<String>(
          'endpoint', null, () async => 'new',
          usePersistentCache: true, forceRefresh: true);
      final cached = await cache.getOrFetch<String>(
          'endpoint', null, () async => 'not fetched',
          usePersistentCache: true);

      expect(result, 'new');
      expect(cached, 'new');
    });

    test('should serve the cached entry when a forced refresh fails', () async {
      await cache.getOrFetch<String>('endpoint', null, () async => 'cached',
          cacheDuration: const Duration(minutes: 3), usePersistentCache: true);

      final result = await cache.getOrFetch<String>(
          'endpoint', null, () async => throw Exception('offline'),
          usePersistentCache: true, forceRefresh: true);

      expect(result, 'cached');
    });

    group('with a version', () {
      const expired = Duration(milliseconds: -1);
      var fetches = 0;
      var serverVersion = 'v1';

      Future<String> get({bool forceRefresh = false}) =>
          cache.getOrFetch<String>(
            'versioned',
            null,
            () async => 'data ${++fetches}',
            cacheDuration: expired,
            usePersistentCache: true,
            forceRefresh: forceRefresh,
            version: () async => serverVersion,
          );

      setUp(() {
        fetches = 0;
        serverVersion = 'v1';
      });

      test('keeps an expired entry while the version is unchanged', () async {
        expect(await get(), 'data 1');
        expect(await get(), 'data 1');
        expect(fetches, 1);
      });

      test('fetches again once the version changes', () async {
        await get();
        serverVersion = 'v2';
        expect(await get(), 'data 2');
        expect(await get(), 'data 2');
        expect(fetches, 2);
      });

      test('keeps an unchanged persistent entry after a restart', () async {
        await get();
        cache = ApiCache.forTesting(directory: directory);
        await cache.initialize();
        expect(await get(), 'data 1');
        expect(fetches, 1);
      });

      test('fetches when the version is unknown', () async {
        Future<String> getUnversioned() => cache.getOrFetch<String>(
              'unversioned',
              null,
              () async => 'data ${++fetches}',
              cacheDuration: expired,
              version: () async => null,
            );
        await getUnversioned();
        expect(await getUnversioned(), 'data 2');
      });

      test('fetches despite an unchanged version with forceRefresh', () async {
        await get();
        expect(await get(forceRefresh: true), 'data 2');
      });

      test('serves the stale entry when the version check fails', () async {
        await get();
        final result = await cache.getOrFetch<String>(
          'versioned',
          null,
          () async => 'data ${++fetches}',
          cacheDuration: expired,
          version: () async => throw Exception('offline'),
        );
        expect(result, 'data 1');
        expect(fetches, 1);
      });
    });

    test('should rethrow when fetch fails and nothing is cached', () async {
      expect(
        cache.getOrFetch<String>(
            'endpoint', null, () async => throw Exception('offline')),
        throwsException,
      );
    });
  });
}
