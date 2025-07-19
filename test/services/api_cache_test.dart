import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/api_cache.dart';

void main() {
  group('API Cache Tests', () {
    late ApiCache cache;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      cache = ApiCache.forTesting();
      await cache.initialize();
    });

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

    test('should provide cache statistics', () async {
      const endpoint = 'test_endpoint';
      const params = {'param1': 'value1'};

      await cache.getOrFetch<String>(
        endpoint,
        params,
        () async => 'result',
        cacheDuration: const Duration(seconds: 10),
      );

      final stats = cache.getStats();
      expect(stats['total'], 1);
      expect(stats['valid'], 1);
      expect(stats['expired'], 0);
      expect(stats['ongoingRequests'], 0);
    });

    test('should invalidate cache by pattern', () async {
      const endpoint1 = 'getAlbumList';
      const endpoint2 = 'getAlbum';
      const endpoint3 = 'getArtist';
      const params = {'param1': 'value1'};

      var callCount = 0;
      Future<String> fetchData() async {
        callCount++;
        return 'result_$callCount';
      }

      // Cache multiple endpoints
      await cache.getOrFetch<String>(endpoint1, params, fetchData,
          cacheDuration: const Duration(seconds: 10));
      await cache.getOrFetch<String>(endpoint2, params, fetchData,
          cacheDuration: const Duration(seconds: 10));
      await cache.getOrFetch<String>(endpoint3, params, fetchData,
          cacheDuration: const Duration(seconds: 10));

      expect(callCount, 3);

      // Invalidate album-related cache
      cache.invalidatePattern('getAlbum');

      // getAlbumList and getAlbum should be cleared, getArtist should remain
      await cache.getOrFetch<String>(endpoint1, params, fetchData,
          cacheDuration: const Duration(seconds: 10));
      await cache.getOrFetch<String>(endpoint2, params, fetchData,
          cacheDuration: const Duration(seconds: 10));
      await cache.getOrFetch<String>(endpoint3, params, fetchData,
          cacheDuration: const Duration(seconds: 10));

      expect(callCount, 5); // 2 new fetches for album endpoints
    });
  });
}
