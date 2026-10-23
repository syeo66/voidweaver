import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';

final _log = Logger('api_cache');

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

/// Request deduplication and caching service.
///
/// Persistent entries are JSON files in `api_cache/` in the app cache
/// directory, one per key. They used to be kept in SharedPreferences, which
/// Android loads whole at startup and rewrites whole on every change (also on
/// each playback position save); see [_migrateFromSharedPreferences].
class ApiCache {
  static final ApiCache _instance = ApiCache._internal();
  factory ApiCache() => _instance;
  ApiCache._internal() : _directoryProvider = _defaultDirectory;

  /// Keeps persistent entries in [directory]; without one, only in memory.
  @visibleForTesting
  ApiCache.forTesting({Directory? directory})
      : _directoryProvider = (() async => directory);

  // Old SharedPreferences entries are prefixed with this, see
  // _migrateFromSharedPreferences()
  static const _legacyPrefix = 'cache_';

  final Map<String, CacheEntry<Object?>> _memoryCache = {};
  final Map<String, Completer<Object?>> _ongoingRequests = {};
  final Future<Directory?> Function() _directoryProvider;
  Future<Directory?>? _directory;

  static Future<Directory?> _defaultDirectory() async =>
      Directory('${(await getApplicationCacheDirectory()).path}/api_cache');

  /// Prepares the persistent storage. Called by every operation that needs
  /// it; persistence is off if it fails (e.g. in tests without plugins).
  Future<void> initialize() => _storage();

  Future<Directory?> _storage() => _directory ??= () async {
        try {
          final directory = await _directoryProvider();
          if (directory == null) return null;
          await directory.create(recursive: true);
          await _migrateFromSharedPreferences(directory);
          return directory;
        } catch (e) {
          _log.warning('API cache is not persisted', e);
          return null;
        }
      }();

  static File _fileFor(Directory directory, String key) =>
      File('${directory.path}/${md5.convert(utf8.encode(key))}.json');

  /// Moves entries saved in SharedPreferences by older versions to files, so
  /// the library stays browsable offline after the update. Search results
  /// aren't persisted anymore and are dropped.
  static Future<void> _migrateFromSharedPreferences(Directory directory) async {
    final prefs = await SharedPreferences.getInstance();
    final keys =
        prefs.getKeys().where((k) => k.startsWith(_legacyPrefix)).toList();
    if (keys.isEmpty) return;
    for (final prefKey in keys) {
      final key = prefKey.substring(_legacyPrefix.length);
      final json = prefs.getString(prefKey);
      if (json != null && !key.startsWith('search3?')) {
        await _fileFor(directory, key).writeAsString(json);
      }
      await prefs.remove(prefKey);
    }
    _log.info('Moved ${keys.length} API cache entries to files');
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
      _log.fine('Cache HIT (memory): $key');
      return memoryCached.data as T;
    }

    // Check persistent cache if enabled
    CacheEntry<T>? persistentCached;
    if (usePersistentCache) {
      persistentCached = await _getPersistentCache<T>(key, fromJson);
      if (!forceRefresh &&
          persistentCached != null &&
          persistentCached.isValid) {
        _log.fine('Cache HIT (persistent): $key');
        // Store in memory cache for faster access
        _memoryCache[key] = persistentCached;
        return persistentCached.data;
      }
    }

    // Check if request is already in progress (deduplication)
    if (_ongoingRequests.containsKey(key)) {
      _log.fine('Request DEDUPLICATED: $key');
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
        _log.fine('Cache RENEWED (unchanged on the server): $key');
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
        _log.fine('Cache MISS: $key');
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
        _log.warning('Cache STALE (fetch failed: $error): $key');
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

  // Entries this long (in characters) are decoded on a background isolate,
  // so a large library doesn't stall the UI at startup
  static const _backgroundJsonThreshold = 64 * 1024;

  /// Get data from persistent cache, including expired entries
  Future<CacheEntry<T>?> _getPersistentCache<T>(
      String key, T Function(dynamic json)? fromJson) async {
    final directory = await _storage();
    if (directory == null) return null;
    final file = _fileFor(directory, key);

    try {
      if (!await file.exists()) return null;
      final contents = await file.readAsString();
      final json = (contents.length < _backgroundJsonThreshold
          ? jsonDecode(contents)
          : await compute(jsonDecode, contents)) as Map<String, dynamic>;
      return CacheEntry<T>.fromJson(json, fromJson ?? (data) => data as T);
    } catch (e) {
      _log.warning('Error reading persistent cache for $key', e);
      // Remove corrupted entry
      unawaited(_delete(file));
      return null;
    }
  }

  /// Set data in persistent cache
  Future<void> _setPersistentCache<T>(
      String key, CacheEntry<T> entry, Object? Function(T data)? toJson) async {
    final directory = await _storage();
    if (directory == null) return;
    final file = _fileFor(directory, key);

    try {
      final json = {
        ...entry.toJson(),
        'data': toJson != null ? toJson(entry.data) : entry.data,
      };
      // Lists (the album list, all artists) can be large; single entries
      // aren't worth an isolate
      final jsonString = json['data'] is List
          ? await compute(jsonEncode, json)
          : jsonEncode(json);
      // Written next to it and renamed, so a crash mid-write can't leave a
      // truncated entry
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonString, flush: true);
      await temp.rename(file.path);
    } catch (e) {
      _log.warning('Error writing persistent cache for $key', e);
    }
  }

  static Future<void> _delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      _log.warning('Error removing persistent cache entry', e);
    }
  }

  /// Clear specific cache entry
  void clearEntry(String endpoint, [Map<String, String>? params]) {
    final key = _generateKey(endpoint, params);
    _memoryCache.remove(key);
    unawaited(_storage().then((directory) async {
      if (directory != null) await _delete(_fileFor(directory, key));
    }));
    _log.fine('Cache CLEARED: $key');
  }

  /// Clear all cache entries, also those persisted and never loaded
  Future<void> clearAll() async {
    _memoryCache.clear();
    final directory = await _storage();
    if (directory != null) {
      try {
        await for (final entity in directory.list()) {
          await entity.delete(recursive: true);
        }
      } catch (e) {
        _log.warning('Error removing persistent cache entries', e);
      }
    }

    _log.info('Cache CLEARED ALL');
  }
}
