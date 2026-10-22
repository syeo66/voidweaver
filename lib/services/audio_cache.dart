import 'package:voidweaver_player/voidweaver_player.dart';
import 'package:logging/logging.dart';

import 'replaygain_reader.dart';

final _log = Logger('audio_cache');

/// The player's audio cache, by song: downloads upcoming songs and tells
/// which songs can play without the network.
///
/// The cache itself is the player's ([MediaCache]): songs are cached while
/// they play and cached songs play from it, see docs/CACHING.md. Entries are
/// keyed by [namespace] (the server URL) and song id.
class AudioCache {
  /// Prefix for cache keys, e.g. the server URL, so song ids from different
  /// servers can't collide.
  final String namespace;
  final MediaCache _cache;

  AudioCache({this.namespace = '', MediaCache cache = const MediaCache()})
      : _cache = cache;

  /// The cache key of [songId], see [AudioSource.cacheKey].
  String keyFor(String songId) => '$namespace|$songId';

  /// Downloads [songId] from [url] completely into the cache, unless it's
  /// there already. Returns whether it's completely cached.
  Future<bool> prefetch(String songId, String url) async {
    try {
      await _cache.prefetch(keyFor(songId), Uri.parse(url));
      _log.fine('Cached $songId');
      return true;
    } catch (e) {
      _log.warning('Download failed for $songId', e);
      return false;
    }
  }

  /// The first of [songIds] that's completely cached, if any.
  Future<String?> firstCached(List<String> songIds) async {
    if (songIds.isEmpty) return null;
    final keys = [for (final id in songIds) keyFor(id)];
    final cached = (await _cache.cachedKeys(keys)).toSet();
    for (final id in songIds) {
      if (cached.contains(keyFor(id))) return id;
    }
    return null;
  }

  /// ReplayGain tags of [songId], read from the cache without the network.
  /// Null if its start isn't cached.
  Future<ReplayGainData?> readReplayGain(String songId) async {
    final key = keyFor(songId);
    var available = true;
    final data = await ReplayGainReader.readFromHead((length) async {
      final bytes = await _cache.readHead(key, length);
      if (bytes == null) available = false;
      return bytes;
    });
    return available ? data : null;
  }

  /// Size of cached audio in bytes (of all servers).
  Future<int> sizeInBytes() => _cache.sizeInBytes();

  /// Removes all cached audio.
  Future<void> clear() => _cache.clear();
}
