import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
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

  /// Whether the entry has expired at [now]
  bool isExpiredAt(DateTime now) => now.isAfter(expiresAt);

  Map<String, dynamic> toJson() => {
    'data': data,
    'expiresAt': expiresAt.toIso8601String(),
    'key': key,
    if (version != null) 'version': version,
  };

  factory CacheEntry.fromJson(
    Map<String, dynamic> json,
    T Function(dynamic) fromJsonData,
  ) {
    return CacheEntry<T>(
      data: fromJsonData(json['data']),
      expiresAt: DateTime.parse(json['expiresAt'] as String),
      key: json['key'] as String,
      version: json['version'] as String?,
    );
  }
}

/// What [ApiCache.getOrFetchResult] returns: the data, and whether it's the
/// fallback to a cached entry because the fetch failed.
class CacheResult<T> {
  final T data;

  /// Why the data couldn't be fetched, if [data] is the fallback to the
  /// cached entry; null if it's fresh (fetched, or a cache hit that didn't
  /// need fetching)
  final Object? fetchError;

  const CacheResult(this.data, {this.fetchError});

  /// Whether [data] is the cached entry because the fetch failed
  bool get isStale => fetchError != null;
}

/// Request deduplication and caching service for one login.
///
/// Each [SubsonicApi] has its own cache, scoped by its [namespace] (server and
/// user): the memory cache and the requests in progress belong to the
/// instance, and persistent entries are JSON files in
/// `api_cache/<md5 of namespace>/` in the app cache directory, one per key.
/// So one login never sees another's data, and after [close] (logout) a fetch
/// that was still running stores nothing.
class ApiCache {
  ApiCache({required this.namespace, this._clock = DateTime.now})
    : _rootProvider = _defaultRoot,
      _maxMemoryEntries = defaultMaxMemoryEntries;

  /// Keeps persistent entries under [directory]; without one, only in memory.
  @visibleForTesting
  ApiCache.forTesting({
    Directory? directory,
    this.namespace = 'test',
    this._maxMemoryEntries = defaultMaxMemoryEntries,
    this._clock = DateTime.now,
  }) : _rootProvider = (() async => directory);

  /// How many entries the memory cache keeps, see [_remember]. Every album
  /// opened and every search adds one, so without a limit a long session
  /// would only grow it.
  static const defaultMaxMemoryEntries = 200;

  /// Identifies the login the entries belong to
  final String namespace;

  final Map<String, CacheEntry<Object?>> _memoryCache = {};
  final Map<String, Completer<CacheResult<Object?>>> _ongoingRequests = {};
  final int _maxMemoryEntries;
  final Future<Directory?> Function() _rootProvider;
  // When entries expire is measured against this
  final DateTime Function() _clock;
  Future<_Storage?>? _storageFuture;
  final Set<Future<void>> _pendingWrites = {};
  bool _closed = false;

  static Future<Directory?> _defaultRoot() async =>
      Directory('${(await getApplicationCacheDirectory()).path}/api_cache');

  /// Prepares the persistent storage. Called by every operation that needs
  /// it; persistence is off if it fails (e.g. in tests without plugins).
  Future<void> initialize() => _storage();

  Future<_Storage?> _storage() => _storageFuture ??= () async {
    try {
      final root = await _rootProvider();
      if (root == null) return null;
      final scope = Directory(
        '${root.path}/${md5.convert(utf8.encode(namespace))}',
      );
      await scope.create(recursive: true);
      return _Storage(root, scope);
    } catch (e) {
      _log.warning('API cache is not persisted', e);
      return null;
    }
  }();

  bool _isExpired(CacheEntry<Object?> entry) => entry.isExpiredAt(_clock());

  static File _fileFor(Directory directory, String key) =>
      File('${directory.path}/${md5.convert(utf8.encode(key))}.json');

  /// Stops storing results: fetches still running finish for their callers,
  /// but their data isn't cached, in memory or on disk. For a logout, so
  /// nothing writes the server's data again after it was removed.
  void close() {
    _closed = true;
    _memoryCache.clear();
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
  ///
  /// Use [getOrFetchResult] to tell the stale fallback from fresh data.
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
  }) async => (await getOrFetchResult<T>(
    endpoint,
    params,
    fetcher,
    cacheDuration: cacheDuration,
    usePersistentCache: usePersistentCache,
    forceRefresh: forceRefresh,
    toJson: toJson,
    fromJson: fromJson,
    version: version,
  )).data;

  /// Like [getOrFetch], but tells whether the data is the fallback to a
  /// cached entry because the fetch failed ([CacheResult.isStale]), for
  /// callers that keep track of when their data was last up to date. Also
  /// for a request deduplicated onto one that fell back.
  Future<CacheResult<T>> getOrFetchResult<T>(
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
    if (!forceRefresh && memoryCached != null && !_isExpired(memoryCached)) {
      _log.fine('Cache HIT (memory): $key');
      // Now the most recently used, see _remember()
      _remember(key, memoryCached);
      return CacheResult(memoryCached.data as T);
    }

    // Check persistent cache if enabled
    CacheEntry<T>? persistentCached;
    if (usePersistentCache) {
      persistentCached = await _getPersistentCache<T>(key, fromJson);
      if (!forceRefresh &&
          persistentCached != null &&
          !_isExpired(persistentCached)) {
        _log.fine('Cache HIT (persistent): $key');
        // Store in memory cache for faster access
        _remember(key, persistentCached);
        return CacheResult(persistentCached.data);
      }
    }

    // Check if request is already in progress (deduplication)
    if (_ongoingRequests.containsKey(key)) {
      _log.fine('Request DEDUPLICATED: $key');
      final shared = await _ongoingRequests[key]!.future;
      return CacheResult(shared.data as T, fetchError: shared.fetchError);
    }

    // Start new request
    final completer = Completer<CacheResult<T>>();
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
        _remember(
          key,
          CacheEntry<T>(
            data: result,
            expiresAt: _clock().add(cacheDuration),
            key: key,
            version: currentVersion,
          ),
        );
      } else {
        _log.fine('Cache MISS: $key');
        result = await fetcher();

        // Store in memory cache
        final entry = CacheEntry<T>(
          data: result,
          expiresAt: _clock().add(cacheDuration),
          key: key,
          version: currentVersion,
        );
        _remember(key, entry);

        // Store in persistent cache if enabled
        if (usePersistentCache && !_closed) {
          final write = _setPersistentCache(key, entry, toJson);
          _pendingWrites.add(write);
          try {
            await write;
          } finally {
            _pendingWrites.remove(write);
          }
        }
      }

      final fresh = CacheResult(result);
      completer.complete(fresh);
      return fresh;
    } catch (error) {
      // Fall back to stale data rather than failing outright
      final stale = memoryCached ?? persistentCached;
      if (stale != null) {
        _log.warning('Cache STALE (fetch failed: $error): $key');
        _remember(key, stale);
        final fallback = CacheResult(stale.data as T, fetchError: error);
        completer.complete(fallback);
        return fallback;
      }
      completer.completeError(error);
      rethrow;
    } finally {
      _ongoingRequests.remove(key);
    }
  }

  /// Stores [entry] as the most recently used one. Beyond
  /// [_maxMemoryEntries], expired entries go first (least recently used
  /// first), then the least recently used of the others. Never [key] itself.
  /// A fetch that fails still has the stale entry it started with in a local
  /// variable, so the fallback in [getOrFetch] doesn't depend on what's kept
  /// here.
  ///
  /// Expired entries are kept while there's room: the memory cache is the
  /// only stale fallback for data that isn't persisted (searches).
  void _remember(String key, CacheEntry<Object?> entry) {
    if (_closed) return;
    // Removed first, so it moves to the end of the (insertion-ordered) map
    _memoryCache.remove(key);
    _memoryCache[key] = entry;
    var excess = _memoryCache.length - _maxMemoryEntries;
    if (excess <= 0) return;
    // [key] stays, expired or not: it's the entry just stored or used
    final others = [
      for (final e in _memoryCache.entries)
        if (e.key != key) e,
    ];
    for (final e in others) {
      if (excess <= 0) return;
      if (_isExpired(e.value)) {
        _memoryCache.remove(e.key);
        excess--;
      }
    }
    for (final e in others) {
      if (excess <= 0) return;
      if (_memoryCache.remove(e.key) != null) excess--;
    }
  }

  // Entries this long (in characters) are decoded on a background isolate,
  // so a large library doesn't stall the UI at startup
  static const _backgroundJsonThreshold = 64 * 1024;

  /// Get data from persistent cache, including expired entries
  Future<CacheEntry<T>?> _getPersistentCache<T>(
    String key,
    T Function(dynamic json)? fromJson,
  ) async {
    final storage = await _storage();
    if (storage == null) return null;
    final file = _fileFor(storage.scope, key);

    try {
      if (!await file.exists()) return null;
      final contents = await file.readAsString();
      final json =
          (contents.length < _backgroundJsonThreshold
                  ? jsonDecode(contents)
                  : await compute(jsonDecode, contents))
              as Map<String, dynamic>;
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
    String key,
    CacheEntry<T> entry,
    Object? Function(T data)? toJson,
  ) async {
    final storage = await _storage();
    if (storage == null) return;
    final file = _fileFor(storage.scope, key);

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
    unawaited(
      _storage().then((storage) async {
        if (storage != null) await _delete(_fileFor(storage.scope, key));
      }),
    );
    _log.fine('Cache CLEARED: $key');
  }

  /// Clear all cache entries, also those persisted and never loaded, and
  /// those of other logins left behind. Waits for writes in progress first,
  /// so none of them lands after the clear.
  Future<void> clearAll() async {
    _memoryCache.clear();
    final storage = await _storage();
    await Future.wait(_pendingWrites.toList());
    if (storage != null) {
      try {
        await for (final entity in storage.root.list()) {
          await entity.delete(recursive: true);
        }
        if (!_closed) await storage.scope.create(recursive: true);
      } catch (e) {
        _log.warning('Error removing persistent cache entries', e);
      }
    }

    _log.info('Cache CLEARED ALL');
  }
}

/// Where persistent entries are kept: [scope] for this login's, inside
/// [root] with those of any other login
class _Storage {
  final Directory root;
  final Directory scope;

  const _Storage(this.root, this.scope);
}
