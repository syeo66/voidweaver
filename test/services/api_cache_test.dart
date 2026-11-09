import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/api_cache.dart';
import 'package:voidweaver/services/subsonic_api.dart';

/// The files under [directory], in all scopes
List<File> filesIn(Directory directory) =>
    directory.listSync(recursive: true).whereType<File>().toList();

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
      final result = await cache.getOrFetch<String>(endpoint, params, () async {
        callCount++;
        return expectedResult;
      }, cacheDuration: const Duration(seconds: 10));

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
        return cache.getOrFetch<String>(endpoint, params, () async {
          callCount++;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return expectedResult;
        }, cacheDuration: const Duration(seconds: 10));
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
      await Future<void>.delayed(const Duration(milliseconds: 100));

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
        Album(
          id: 'a1',
          name: 'First',
          artist: 'Artist',
          songs: [
            Song(id: 's1', title: 'Song', artist: 'Artist', album: 'First'),
          ],
        ),
      ];
      Object? toJson(List<Album> data) => data.map((a) => a.toJson()).toList();
      List<Album> fromJson(dynamic json) => (json as List<dynamic>)
          .map((a) => Album.fromJson(a as Map<String, dynamic>))
          .toList();

      await cache.getOrFetch<List<Album>>(
        'getAlbumList2',
        null,
        () async => albums,
        usePersistentCache: true,
        toJson: toJson,
        fromJson: fromJson,
      );

      // A fresh instance (e.g. after app restart) has an empty memory cache
      final restarted = ApiCache.forTesting(directory: directory);
      await restarted.initialize();
      var fetched = false;
      final result = await restarted.getOrFetch<List<Album>>(
        'getAlbumList2',
        null,
        () async {
          fetched = true;
          return <Album>[];
        },
        usePersistentCache: true,
        toJson: toJson,
        fromJson: fromJson,
      );

      expect(fetched, isFalse);
      expect(result, albums);
    });

    test('persists entries too large to decode on the UI isolate', () async {
      final large = 'x' * (128 * 1024);
      await cache.getOrFetch<List<String>>(
        'large',
        null,
        () async => [large],
        usePersistentCache: true,
        fromJson: (json) => (json as List<dynamic>).cast<String>(),
      );

      final restarted = ApiCache.forTesting(directory: directory);
      await restarted.initialize();
      final result = await restarted.getOrFetch<List<String>>(
        'large',
        null,
        () async => fail('read from the file'),
        usePersistentCache: true,
        fromJson: (json) => (json as List<dynamic>).cast<String>(),
      );

      expect(result, [large]);
    });

    test(
      'clearAll removes persisted entries before the cache was used',
      () async {
        await cache.getOrFetch<String>(
          'endpoint',
          null,
          () async => 'saved',
          usePersistentCache: true,
        );

        // Not initialized and nothing loaded, as right after a restart
        final restarted = ApiCache.forTesting(directory: directory);
        await restarted.clearAll();

        expect(filesIn(directory), isEmpty);
      },
    );

    test('a corrupted file is dropped and fetched again', () async {
      await cache.getOrFetch<String>(
        'endpoint',
        null,
        () async => 'saved',
        usePersistentCache: true,
      );
      final file = filesIn(directory).single;
      file.writeAsStringSync('{not json');

      final restarted = ApiCache.forTesting(directory: directory);
      final result = await restarted.getOrFetch<String>(
        'endpoint',
        null,
        () async => 'fetched',
        usePersistentCache: true,
      );

      expect(result, 'fetched');
    });

    test('works in memory when the storage is unavailable', () async {
      final memoryOnly = ApiCache.forTesting();
      await memoryOnly.getOrFetch<String>(
        'endpoint',
        null,
        () async => 'a',
        usePersistentCache: true,
      );
      final result = await memoryOnly.getOrFetch<String>(
        'endpoint',
        null,
        () async => 'b',
        usePersistentCache: true,
      );

      expect(result, 'a');
    });

    test('should serve stale memory data when fetch fails', () async {
      await cache.getOrFetch<String>(
        'endpoint',
        null,
        () async => 'fresh',
        cacheDuration: Duration.zero,
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final result = await cache.getOrFetch<String>(
        'endpoint',
        null,
        () async => throw Exception('offline'),
      );

      expect(result, 'fresh');
    });

    test(
      'should serve stale persistent data when fetch fails after restart',
      () async {
        await cache.getOrFetch<String>(
          'endpoint',
          null,
          () async => 'saved',
          cacheDuration: Duration.zero,
          usePersistentCache: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));

        final restarted = ApiCache.forTesting(directory: directory);
        await restarted.initialize();
        final result = await restarted.getOrFetch<String>(
          'endpoint',
          null,
          () async => throw Exception('offline'),
          usePersistentCache: true,
        );

        expect(result, 'saved');
      },
    );

    test('should fetch despite a valid entry with forceRefresh', () async {
      await cache.getOrFetch<String>(
        'endpoint',
        null,
        () async => 'old',
        cacheDuration: const Duration(minutes: 3),
        usePersistentCache: true,
      );

      final result = await cache.getOrFetch<String>(
        'endpoint',
        null,
        () async => 'new',
        usePersistentCache: true,
        forceRefresh: true,
      );
      final cached = await cache.getOrFetch<String>(
        'endpoint',
        null,
        () async => 'not fetched',
        usePersistentCache: true,
      );

      expect(result, 'new');
      expect(cached, 'new');
    });

    test('should serve the cached entry when a forced refresh fails', () async {
      await cache.getOrFetch<String>(
        'endpoint',
        null,
        () async => 'cached',
        cacheDuration: const Duration(minutes: 3),
        usePersistentCache: true,
      );

      final result = await cache.getOrFetch<String>(
        'endpoint',
        null,
        () async => throw Exception('offline'),
        usePersistentCache: true,
        forceRefresh: true,
      );

      expect(result, 'cached');
    });

    // Callers that keep track of when their data was last up to date (the
    // album list's sync) must tell the fallback from fresh data
    group('getOrFetchResult', () {
      const expired = Duration(milliseconds: -1);
      const offline = SocketException('offline');

      Future<CacheResult<String>> get(
        Future<String> Function() fetcher, {
        Duration cacheDuration = expired,
        bool forceRefresh = false,
        Future<String?> Function()? version,
        ApiCache? from,
        bool persistent = true,
      }) => (from ?? cache).getOrFetchResult<String>(
        'endpoint',
        null,
        fetcher,
        cacheDuration: cacheDuration,
        usePersistentCache: persistent,
        forceRefresh: forceRefresh,
        version: version,
      );

      test('fetched data is fresh', () async {
        final result = await get(() async => 'fetched');
        expect(result.data, 'fetched');
        expect(result.isStale, isFalse);
        expect(result.fetchError, isNull);
      });

      test('a cache hit is fresh, from memory and from storage', () async {
        await get(
          () async => 'cached',
          cacheDuration: const Duration(hours: 1),
        );

        final memory = await get(() async => 'not fetched');
        expect(memory.data, 'cached');
        expect(memory.isStale, isFalse);

        final restarted = ApiCache.forTesting(directory: directory);
        await restarted.initialize();
        final stored = await get(() async => 'not fetched', from: restarted);
        expect(stored.data, 'cached');
        expect(stored.isStale, isFalse);
      });

      test('an entry renewed for an unchanged version is fresh', () async {
        await get(() async => 'v1 data', version: () async => 'v1');
        final renewed = await get(
          () async => 'not fetched',
          version: () async => 'v1',
        );
        expect(renewed.data, 'v1 data');
        expect(renewed.isStale, isFalse);
      });

      test('the expired memory entry is stale when the fetch fails', () async {
        await get(() async => 'old');
        final result = await get(() async => throw offline);
        expect(result.data, 'old');
        expect(result.isStale, isTrue);
        expect(result.fetchError, same(offline));
      });

      test(
        'the stored entry is stale when the fetch fails after a restart',
        () async {
          await get(() async => 'saved');
          final restarted = ApiCache.forTesting(directory: directory);
          await restarted.initialize();

          final result = await get(() async => throw offline, from: restarted);
          expect(result.data, 'saved');
          expect(result.fetchError, same(offline));
        },
      );

      test('a valid entry is stale when a forced refresh fails', () async {
        await get(() async => 'valid', cacheDuration: const Duration(hours: 1));
        final result = await get(() async => throw offline, forceRefresh: true);
        expect(result.data, 'valid');
        expect(result.fetchError, same(offline));
      });

      test('the entry is stale when the version check fails', () async {
        await get(() async => 'v1 data', version: () async => 'v1');
        final result = await get(
          () async => 'not fetched',
          version: () async => throw offline,
        );
        expect(result.data, 'v1 data');
        expect(result.fetchError, same(offline));
      });

      /// Two requests for the expired entry, the second while the first
      /// fetches, which ends with [end]
      Future<List<CacheResult<String>>> deduplicated(
        void Function(Completer<String> fetching) end,
      ) async {
        await get(() async => 'old');
        final fetching = Completer<String>();
        final started = Completer<void>();
        final first = get(() {
          started.complete();
          return fetching.future;
        });
        // Registered as in progress once it fetches
        await started.future;
        // Without storage, it joins the first synchronously, before [end]
        final second = get(() async => 'not fetched', persistent: false);
        end(fetching);
        return Future.wait([first, second]);
      }

      test('a request deduplicated onto a failing one is stale too', () async {
        final results = await deduplicated((f) => f.completeError(offline));
        for (final result in results) {
          expect(result.data, 'old');
          expect(result.fetchError, same(offline));
        }
      });

      test('a request deduplicated onto a successful one is fresh', () async {
        final results = await deduplicated((f) => f.complete('new'));
        for (final result in results) {
          expect(result.data, 'new');
          expect(result.isStale, isFalse);
        }
      });

      test('nothing cached: the error is thrown', () async {
        await expectLater(
          get(() async => throw offline),
          throwsA(same(offline)),
        );
      });
    });

    group('memory limit', () {
      late ApiCache small;
      late Map<String, int> fetches;

      setUp(() {
        small = ApiCache.forTesting(directory: directory, maxMemoryEntries: 3);
        fetches = {};
      });

      /// Fetches [key] with a fetcher that counts its calls
      Future<String> get(
        String key, {
        Duration duration = const Duration(minutes: 5),
      }) => small.getOrFetch<String>(key, null, () async {
        fetches[key] = (fetches[key] ?? 0) + 1;
        return 'v$key';
      }, cacheDuration: duration);

      test('drops the least recently used entry beyond the limit', () async {
        for (final key in ['a', 'b', 'c', 'd']) {
          await get(key);
        }

        // c and d are still cached, a was dropped
        await get('d');
        await get('c');
        expect(fetches, {'a': 1, 'b': 1, 'c': 1, 'd': 1});
        await get('a');
        expect(fetches['a'], 2);
      });

      test('a hit counts as a use', () async {
        for (final key in ['a', 'b', 'c']) {
          await get(key);
        }
        await get('a');
        await get('d');

        // b was the least recently used; a, c and d are kept
        await get('a');
        await get('c');
        await get('d');
        expect(fetches, {'a': 1, 'b': 1, 'c': 1, 'd': 1});
        await get('b');
        expect(fetches['b'], 2);
      });

      test('drops expired entries before fresh ones', () async {
        await get('a');
        await get('b', duration: Duration.zero);
        await get('c');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await get('d');

        // b expired and went; a is older but fresh and stays
        await get('a');
        await get('c');
        await get('d');
        expect(fetches, {'a': 1, 'b': 1, 'c': 1, 'd': 1});
      });

      test('stays within the limit, however many keys are used', () async {
        for (var i = 0; i < 50; i++) {
          await get('key$i');
        }

        // Only the last three are cached
        for (var i = 47; i < 50; i++) {
          await get('key$i');
        }
        expect(fetches.values.every((count) => count == 1), isTrue);
        await get('key46');
        expect(fetches['key46'], 2);
      });

      test('a stale entry still serves a failed fetch', () async {
        await get('a', duration: Duration.zero);
        await get('b');
        await Future<void>.delayed(const Duration(milliseconds: 5));

        final result = await small.getOrFetch<String>(
          'a',
          null,
          () async => throw Exception('offline'),
        );

        expect(result, 'va');
      });

      test(
        'a fetch failing after its entry was dropped still serves it',
        () async {
          final single = ApiCache.forTesting(
            directory: directory,
            maxMemoryEntries: 1,
          );
          await single.getOrFetch<String>(
            'a',
            null,
            () async => 'va',
            cacheDuration: Duration.zero,
          );
          await Future<void>.delayed(const Duration(milliseconds: 5));

          final fetch = Completer<String>();
          final pending = single.getOrFetch<String>(
            'a',
            null,
            () => fetch.future,
          );
          // Another key's entry pushes a's out of the memory cache
          await single.getOrFetch<String>('b', null, () async => 'vb');
          fetch.completeError(Exception('offline'));

          expect(await pending, 'va');
          // The entry that served the fallback is kept, not the fresh one
          var refetched = false;
          expect(
            await single.getOrFetch<String>('b', null, () async {
              refetched = true;
              return 'vb2';
            }),
            'vb2',
          );
          expect(refetched, isTrue);
        },
      );
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

    group('scopes', () {
      Future<String> get(
        ApiCache cache,
        String value, {
        bool persistent = true,
      }) => cache.getOrFetch<String>(
        'endpoint',
        null,
        () async => value,
        usePersistentCache: persistent,
      );

      test('another login sees neither memory nor persisted entries', () async {
        final serverA = ApiCache.forTesting(
          directory: directory,
          namespace: 'https://a|user',
        );
        final serverB = ApiCache.forTesting(
          directory: directory,
          namespace: 'https://b|user',
        );

        expect(await get(serverA, 'from A'), 'from A');
        expect(await get(serverB, 'from B'), 'from B');

        final restartedA = ApiCache.forTesting(
          directory: directory,
          namespace: 'https://a|user',
        );
        expect(await get(restartedA, 'fetched again'), 'from A');
      });

      test('the same server with another user is another scope', () async {
        final alice = ApiCache.forTesting(
          directory: directory,
          namespace: 'https://a|alice',
        );
        final bob = ApiCache.forTesting(
          directory: directory,
          namespace: 'https://a|bob',
        );

        await get(alice, 'alice');
        expect(await get(bob, 'bob'), 'bob');
      });

      test('a fetch finishing after close() stores nothing', () async {
        final fetch = Completer<String>();
        final loggedOut = ApiCache.forTesting(directory: directory);
        final result = loggedOut.getOrFetch<String>(
          'endpoint',
          null,
          () => fetch.future,
          usePersistentCache: true,
        );
        // Let it reach the fetcher
        await Future<void>.delayed(Duration.zero);

        loggedOut.close();
        await loggedOut.clearAll();
        fetch.complete('late');

        // Its caller still gets the result, but nothing is kept
        expect(await result, 'late');
        expect(filesIn(directory), isEmpty);
        final relogin = ApiCache.forTesting(directory: directory);
        expect(await get(relogin, 'fresh'), 'fresh');
      });

      test('clearAll waits for a write in progress', () async {
        final writing = Completer<void>();
        final saving = cache.getOrFetch<List<String>>(
          'large',
          null,
          () async => List.filled(200000, 'entry'),
          usePersistentCache: true,
          toJson: (data) {
            // Called when the write starts; the list is then encoded on an
            // isolate, so the write is still running when clearAll() starts
            writing.complete();
            return data;
          },
          fromJson: (json) => (json as List<dynamic>).cast<String>(),
        );
        await writing.future;

        await cache.clearAll();
        await saving;

        expect(filesIn(directory), isEmpty);
      });

      test('clearAll removes the entries of other logins too', () async {
        final other = ApiCache.forTesting(
          directory: directory,
          namespace: 'https://other|user',
        );
        await get(other, 'other');
        await get(cache, 'mine');

        await cache.clearAll();

        expect(filesIn(directory), isEmpty);
        // Still usable afterwards
        await get(cache, 'again');
        expect(filesIn(directory), hasLength(1));
      });
    });

    test('should rethrow when fetch fails and nothing is cached', () async {
      expect(
        cache.getOrFetch<String>(
          'endpoint',
          null,
          () async => throw Exception('offline'),
        ),
        throwsException,
      );
    });
  });
}
