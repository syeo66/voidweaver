import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_plus/http_plus.dart' as http_plus;
import 'package:path_provider/path_provider.dart';

/// Disk cache of fully downloaded audio files, keyed by song id.
///
/// Upcoming tracks are downloaded ahead of time so playback can continue
/// when the network drops. Files are evicted least-recently-used once the
/// cache grows past [maxBytes].
class AudioCache {
  static const int defaultMaxBytes = 1024 * 1024 * 1024; // 1 GB

  final int maxBytes;

  /// Prefix for cache keys, e.g. the server URL, so song ids from different
  /// servers can't collide.
  final String namespace;
  final http.Client _client;
  final Future<Directory> Function() _directoryProvider;

  Directory? _directory;
  Future<void>? _initFuture;
  final Map<String, File> _index = {};
  final Map<String, Future<File?>> _downloads = {};
  bool _disposed = false;

  AudioCache({
    this.maxBytes = defaultMaxBytes,
    this.namespace = '',
    http.Client? client,
    Future<Directory> Function()? directoryProvider,
  })  : _client = client ??
            http_plus.HttpPlusClient(enableHttp2: true, maxOpenConnections: 4),
        _directoryProvider = directoryProvider ?? _defaultDirectory;

  static Future<Directory> _defaultDirectory() async {
    final base = await getApplicationCacheDirectory();
    return Directory('${base.path}/audio_cache');
  }

  /// Scans the cache directory, dropping partial downloads from earlier runs.
  Future<void> initialize() => _initFuture ??= _initialize();

  Future<void> _initialize() async {
    try {
      final dir = await _directoryProvider();
      await dir.create(recursive: true);
      _directory = dir;

      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.endsWith('.part')) {
          await entity.delete().catchError((_) => entity);
          continue;
        }
        _index[name.split('.').first] = entity;
      }
      debugPrint('[audio_cache] Initialized with ${_index.length} files');
    } catch (e) {
      debugPrint('[audio_cache] Failed to initialize: $e');
    }
  }

  String _keyFor(String songId) =>
      sha1.convert(utf8.encode('$namespace|$songId')).toString();

  /// Returns the cached file for [songId], or null if it isn't fully cached.
  File? getCachedFile(String songId) {
    final file = _existingFile(songId);
    if (file == null) return null;
    // Mark as recently used for LRU eviction
    try {
      file.setLastModifiedSync(DateTime.now());
    } catch (_) {}
    return file;
  }

  /// Whether [songId] is cached, without marking it as recently used.
  bool isCached(String songId) => _existingFile(songId) != null;

  /// Indexed file for [songId], dropping the entry if the OS deleted it.
  File? _existingFile(String songId) {
    final key = _keyFor(songId);
    final file = _index[key];
    if (file == null) return null;
    if (!file.existsSync()) {
      _index.remove(key);
      return null;
    }
    return file;
  }

  /// Downloads [songId] from [url] unless it's already cached or in flight.
  /// Returns the cached file, or null if the download failed.
  Future<File?> prefetch(String songId, String url, {String? suffix}) async {
    await initialize();
    if (_directory == null || _disposed) return null;

    final cached = getCachedFile(songId);
    if (cached != null) return cached;

    final key = _keyFor(songId);
    return _downloads[key] ??=
        _download(key, songId, url, suffix).whenComplete(() {
      _downloads.remove(key);
    });
  }

  Future<File?> _download(
      String key, String songId, String url, String? suffix) async {
    final partFile = File('${_directory!.path}/$key.part');
    IOSink? sink;
    try {
      final response = await _client.send(http.Request('GET', Uri.parse(url)));
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw HttpException('HTTP ${response.statusCode}');
      }
      // Subsonic reports errors as a 200 XML/JSON body instead of audio
      final contentType = response.headers['content-type'] ?? '';
      if (contentType.contains('xml') || contentType.contains('json')) {
        await response.stream.drain<void>();
        throw const FormatException('Server returned an error document');
      }

      sink = partFile.openWrite();
      await sink.addStream(response.stream);
      await sink.close();
      sink = null;

      final expected = response.contentLength;
      final actual = await partFile.length();
      if (expected != null && expected != actual) {
        throw HttpException('Incomplete download ($actual of $expected bytes)');
      }

      final ext = _extensionFor(contentType, suffix);
      final file = await partFile.rename('${_directory!.path}/$key.$ext');
      _index[key] = file;
      debugPrint('[audio_cache] Cached $songId ($actual bytes)');

      await _evictIfNeeded(protect: {key});
      return file;
    } catch (e) {
      debugPrint('[audio_cache] Download failed for $songId: $e');
      await sink?.close().catchError((_) {});
      if (await partFile.exists()) {
        await partFile.delete().catchError((_) => partFile);
      }
      return null;
    }
  }

  /// File extension so platform players can identify the format.
  static String _extensionFor(String contentType, String? suffix) {
    final mime = contentType.split(';').first.trim().toLowerCase();
    const byMime = {
      'audio/mpeg': 'mp3',
      'audio/mp3': 'mp3',
      'audio/flac': 'flac',
      'audio/x-flac': 'flac',
      'audio/ogg': 'ogg',
      'audio/opus': 'opus',
      'audio/mp4': 'm4a',
      'audio/x-m4a': 'm4a',
      'audio/aac': 'aac',
      'audio/wav': 'wav',
      'audio/x-wav': 'wav',
    };
    final ext = byMime[mime] ?? suffix;
    if (ext == null || !RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext)) {
      return 'audio';
    }
    return ext;
  }

  /// Deletes least recently used files until the cache fits in [maxBytes].
  Future<void> _evictIfNeeded({Set<String> protect = const {}}) async {
    final entries = <MapEntry<String, FileStat>>[];
    var total = 0;
    for (final entry in _index.entries) {
      final stat = await entry.value.stat();
      if (stat.type == FileSystemEntityType.notFound) continue;
      total += stat.size;
      entries.add(MapEntry(entry.key, stat));
    }
    if (total <= maxBytes) return;

    entries.sort((a, b) => a.value.modified.compareTo(b.value.modified));
    for (final entry in entries) {
      if (total <= maxBytes) break;
      if (protect.contains(entry.key)) continue;
      final file = _index.remove(entry.key);
      try {
        await file?.delete();
        total -= entry.value.size;
      } catch (e) {
        debugPrint('[audio_cache] Failed to evict ${entry.key}: $e');
      }
    }
  }

  /// Total size of cached audio in bytes.
  Future<int> sizeInBytes() async {
    await initialize();
    var total = 0;
    for (final file in _index.values) {
      try {
        total += await file.length();
      } catch (_) {}
    }
    return total;
  }

  /// Removes all cached audio.
  Future<void> clear() async {
    await initialize();
    for (final file in _index.values) {
      await file.delete().catchError((_) => file);
    }
    _index.clear();
  }

  void dispose() {
    _disposed = true;
    _client.close();
  }
}
