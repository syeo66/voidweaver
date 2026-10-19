import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cache entry with expiration and data
class CacheEntry<T> {
  final T data;
  final DateTime expiresAt;
  final String key;

  /// The version of the server's data this was fetched at, see
  /// [ApiCache.getOrFetch]
  final String? version;

  CacheEntry({
    required this.data,
    required this.expiresAt,
    required this.key,
    this.version,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);
  bool get isValid => !isExpired;

  Map<String, dynamic> toJson() => {
        'data': data,
        'expiresAt': expiresAt.toIso8601String(),
        'key': key,
        if (version != null) 'version': version,
      };

  factory CacheEntry.fromJson(
      Map<String, dynamic> json, T Function(dynamic) fromJsonData) {
    return CacheEntry<T>(
      data: fromJsonData(json['data']),
      expiresAt: DateTime.parse(json['expiresAt'] as String),
      key: json['key'] as String,
      version: json['version'] as String?,
    );
  }
}

/// Request deduplication and caching service
class ApiCache {
  static final ApiCache _instance = ApiCache._internal();
  factory ApiCache() => _instance;
  ApiCache._internal();

  /// Constructor for testing purposes
  @visibleForTesting
  ApiCache.forTesting();

  final Map<String, CacheEntry<Object?>> _memoryCache = {};
  final Map<String, Completer<Object?>> _ongoingRequests = {};
  SharedPreferences? _prefs;

  /// Initialize persistent storage
  Future<void> initialize() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// Generate cache key from request parameters
  String _generateKey(String endpoint, Map<String, String>? params) {
    final sortedParams = params?.entries.toList();
    sortedParams?.sort((a, b) => a.key.compareTo(b.key));
    final paramString =
        sortedParams?.map((e) => '${e.key}=${e.value}').join('&') ?? '';
    return '$endpoint?$paramString';
  }

  /// Get cached data or execute request with deduplication.
  ///
  /// When [usePersistentCache] is set, [toJson] and [fromJson] convert the
  /// result to and from JSON-encodable data. Without them only values that
  /// survive a JSON round trip unchanged (strings, numbers, ...) can be
  /// persisted.
  ///
  /// If the fetch fails (e.g. the device is offline) and an expired entry is
  /// still available, the stale data is returned instead of the error.
  ///
  /// With [forceRefresh] the data is fetched even if the cached entry hasn't
  /// expired yet; it's still the fallback if the fetch fails.
  ///
  /// [version], if given, is a cheap request for the version of the data on
  /// the server. An expired entry fetched at the same version is kept for
  /// another [cacheDuration] instead of being fetched again. A null version
  /// means unknown, and the data is fetched.
  Future<T> getOrFetch<T>(
    String endpoint,
    Map<String, String>? params,
    Future<T> Function() fetcher, {
    Duration cacheDuration = const Duration(minutes: 5),
    bool usePersistentCache = false,
    bool forceRefresh = false,
    Object? Function(T data)? toJson,
    T Function(dynamic json)? fromJson,
    Future<String?> Function()? version,
  }) async {
    final key = _generateKey(endpoint, params);

    // Check memory cache first
    final memoryCached = _memoryCache[key];
    if (!forceRefresh && memoryCached != null && memoryCached.isValid) {
      debugPrint('Cache HIT (memory): $key');
      return memoryCached.data as T;
    }

    // Check persistent cache if enabled
    CacheEntry<T>? persistentCached;
    if (usePersistentCache) {
      await initialize();
      persistentCached = _getPersistentCache<T>(key, fromJson);
      if (!forceRefresh &&
          persistentCached != null &&
          persistentCached.isValid) {
        debugPrint('Cache HIT (persistent): $key');
        // Store in memory cache for faster access
        _memoryCache[key] = persistentCached;
        return persistentCached.data;
      }
    }

    // Check if request is already in progress (deduplication)
    if (_ongoingRequests.containsKey(key)) {
      debugPrint('Request DEDUPLICATED: $key');
      return await _ongoingRequests[key]!.future as T;
    }

    // Start new request
    final completer = Completer<T>();
    // Errors are rethrown to the caller below; don't also report them as
    // unhandled when no deduplicated request is waiting on this future.
    completer.future.ignore();
    _ongoingRequests[key] = completer;

    try {
      // Asked before fetching, so a change during the fetch shows up as a
      // new version next time
      final currentVersion = await version?.call();
      final cached = memoryCached ?? persistentCached;
      final T result;
      if (!forceRefresh &&
          currentVersion != null &&
          cached != null &&
          cached.version == currentVersion) {
        debugPrint('Cache RENEWED (unchanged on the server): $key');
        result = cached.data as T;
        // Only in memory: rewriting the persistent entry just for its expiry
        // isn't worth it. After a restart the version is checked again.
        _memoryCache[key] = CacheEntry<T>(
          data: result,
          expiresAt: DateTime.now().add(cacheDuration),
          key: key,
          version: currentVersion,
        );
      } else {
        debugPrint('Cache MISS: $key');
        result = await fetcher();

        // Store in memory cache
        final entry = CacheEntry<T>(
          data: result,
          expiresAt: DateTime.now().add(cacheDuration),
          key: key,
          version: currentVersion,
        );
        _memoryCache[key] = entry;

        // Store in persistent cache if enabled
        if (usePersistentCache) {
          await _setPersistentCache(key, entry, toJson);
        }
      }

      completer.complete(result);
      return result;
    } catch (error) {
      // Fall back to stale data rather than failing outright
      final stale = memoryCached ?? persistentCached;
      if (stale != null) {
        debugPrint('Cache STALE (fetch failed: $error): $key');
        _memoryCache[key] = stale;
        completer.complete(stale.data as T);
        return stale.data as T;
      }
      completer.completeError(error);
      rethrow;
    } finally {
      _ongoingRequests.remove(key);
    }
  }

  /// Get data from persistent cache, including expired entries
  CacheEntry<T>? _getPersistentCache<T>(
      String key, T Function(dynamic json)? fromJson) {
    if (_prefs == null) return null;

    try {
      final jsonString = _prefs!.getString('cache_$key');
      if (jsonString == null) return null;

      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return CacheEntry<T>.fromJson(json, fromJson ?? (data) => data as T);
    } catch (e) {
      debugPrint('Error reading persistent cache for $key: $e');
      // Remove corrupted entry
      unawaited(_prefs!.remove('cache_$key'));
      return null;
    }
  }

  /// Set data in persistent cache
  Future<void> _setPersistentCache<T>(
      String key, CacheEntry<T> entry, Object? Function(T data)? toJson) async {
    if (_prefs == null) return;

    try {
      final jsonString = jsonEncode({
        ...entry.toJson(),
        'data': toJson != null ? toJson(entry.data) : entry.data,
      });
      await _prefs!.setString('cache_$key', jsonString);
    } catch (e) {
      debugPrint('Error writing persistent cache for $key: $e');
    }
  }

  /// Clear specific cache entry
  void clearEntry(String endpoint, [Map<String, String>? params]) {
    final key = _generateKey(endpoint, params);
    _memoryCache.remove(key);
    unawaited(_prefs?.remove('cache_$key'));
    debugPrint('Cache CLEARED: $key');
  }

  /// Clear all cache entries
  Future<void> clearAll() async {
    _memoryCache.clear();

    if (_prefs != null) {
      final keys = _prefs!.getKeys().where((key) => key.startsWith('cache_'));
      for (final key in keys) {
        await _prefs!.remove(key);
      }
    }

    debugPrint('Cache CLEARED ALL');
  }

  /// Clear expired entries from memory cache
  void clearExpired() {
    final expiredKeys = _memoryCache.entries
        .where((entry) => entry.value.isExpired)
        .map((entry) => entry.key)
        .toList();

    for (final key in expiredKeys) {
      _memoryCache.remove(key);
    }

    if (expiredKeys.isNotEmpty) {
      debugPrint('Cache CLEARED EXPIRED: ${expiredKeys.length} entries');
    }
  }

  /// Get cache statistics
  Map<String, dynamic> getStats() {
    final total = _memoryCache.length;
    final expired =
        _memoryCache.values.where((entry) => entry.isExpired).length;
    final valid = total - expired;

    return {
      'total': total,
      'valid': valid,
      'expired': expired,
      'ongoingRequests': _ongoingRequests.length,
    };
  }

  /// Invalidate cache entries matching a pattern
  void invalidatePattern(String pattern) {
    final keysToRemove =
        _memoryCache.keys.where((key) => key.contains(pattern)).toList();

    for (final key in keysToRemove) {
      _memoryCache.remove(key);
      unawaited(_prefs?.remove('cache_$key'));
    }

    if (keysToRemove.isNotEmpty) {
      debugPrint(
          'Cache INVALIDATED pattern "$pattern": ${keysToRemove.length} entries');
    }
  }
}
