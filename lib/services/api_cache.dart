import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cache entry with expiration and data
class CacheEntry<T> {
  final T data;
  final DateTime expiresAt;
  final String key;

  CacheEntry({
    required this.data,
    required this.expiresAt,
    required this.key,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);
  bool get isValid => !isExpired;

  Map<String, dynamic> toJson() => {
    'data': data,
    'expiresAt': expiresAt.toIso8601String(),
    'key': key,
  };

  factory CacheEntry.fromJson(Map<String, dynamic> json, T Function(dynamic) fromJsonData) {
    return CacheEntry<T>(
      data: fromJsonData(json['data']),
      expiresAt: DateTime.parse(json['expiresAt']),
      key: json['key'],
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

  final Map<String, CacheEntry> _memoryCache = {};
  final Map<String, Completer> _ongoingRequests = {};
  SharedPreferences? _prefs;

  /// Initialize persistent storage
  Future<void> initialize() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// Generate cache key from request parameters
  String _generateKey(String endpoint, Map<String, String>? params) {
    final sortedParams = params?.entries.toList();
    sortedParams?.sort((a, b) => a.key.compareTo(b.key));
    final paramString = sortedParams?.map((e) => '${e.key}=${e.value}').join('&') ?? '';
    return '$endpoint?$paramString';
  }

  /// Get cached data or execute request with deduplication
  Future<T> getOrFetch<T>(
    String endpoint,
    Map<String, String>? params,
    Future<T> Function() fetcher, {
    Duration cacheDuration = const Duration(minutes: 5),
    bool usePersistentCache = false,
  }) async {
    final key = _generateKey(endpoint, params);
    
    // Check memory cache first
    final memoryCached = _memoryCache[key];
    if (memoryCached != null && memoryCached.isValid) {
      debugPrint('Cache HIT (memory): $key');
      return memoryCached.data as T;
    }

    // Check persistent cache if enabled
    if (usePersistentCache) {
      final persistentCached = await _getPersistentCache<T>(key);
      if (persistentCached != null && persistentCached.isValid) {
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
    _ongoingRequests[key] = completer;

    try {
      debugPrint('Cache MISS: $key');
      final result = await fetcher();
      
      // Store in memory cache
      final entry = CacheEntry<T>(
        data: result,
        expiresAt: DateTime.now().add(cacheDuration),
        key: key,
      );
      _memoryCache[key] = entry;

      // Store in persistent cache if enabled
      if (usePersistentCache) {
        await _setPersistentCache(key, entry);
      }

      completer.complete(result);
      return result;
    } catch (error) {
      completer.completeError(error);
      rethrow;
    } finally {
      _ongoingRequests.remove(key);
    }
  }

  /// Get data from persistent cache
  Future<CacheEntry<T>?> _getPersistentCache<T>(String key) async {
    if (_prefs == null) return null;
    
    try {
      final jsonString = _prefs!.getString('cache_$key');
      if (jsonString == null) return null;

      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return CacheEntry<T>.fromJson(json, (data) => data as T);
    } catch (e) {
      debugPrint('Error reading persistent cache for $key: $e');
      // Remove corrupted entry
      _prefs!.remove('cache_$key');
      return null;
    }
  }

  /// Set data in persistent cache
  Future<void> _setPersistentCache<T>(String key, CacheEntry<T> entry) async {
    if (_prefs == null) return;
    
    try {
      final jsonString = jsonEncode(entry.toJson());
      await _prefs!.setString('cache_$key', jsonString);
    } catch (e) {
      debugPrint('Error writing persistent cache for $key: $e');
    }
  }

  /// Clear specific cache entry
  void clearEntry(String endpoint, [Map<String, String>? params]) {
    final key = _generateKey(endpoint, params);
    _memoryCache.remove(key);
    _prefs?.remove('cache_$key');
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
    final expired = _memoryCache.values.where((entry) => entry.isExpired).length;
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
    final keysToRemove = _memoryCache.keys
        .where((key) => key.contains(pattern))
        .toList();
    
    for (final key in keysToRemove) {
      _memoryCache.remove(key);
      _prefs?.remove('cache_$key');
    }
    
    if (keysToRemove.isNotEmpty) {
      debugPrint('Cache INVALIDATED pattern "$pattern": ${keysToRemove.length} entries');
    }
  }
}