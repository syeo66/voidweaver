import 'package:voidweaver_player/voidweaver_player.dart';
import 'package:logging/logging.dart';

import '../models/subsonic_models.dart';
import 'replaygain_reader.dart';

final _log = Logger('audio_cache');

/// The player's audio cache, by song: downloads upcoming songs and tells
/// which songs can play without the network.
///
/// The cache itself is the player's ([MediaCache]): songs are cached while
/// they play and cached songs play from it, see docs/CACHING.md. Entries are
/// keyed by [namespace] (the server URL), song id and file size, see
/// [keyFor]. The media session's artwork is cached there as well, see
/// [artKeyFor].
class AudioCache {
  /// Prefix for cache keys, e.g. the server URL, so song ids from different
  /// servers can't collide.
  final String namespace;
  final MediaCache _cache;

  AudioCache({this.namespace = '', this._cache = const MediaCache()});

  /// The cache key of [song], see [AudioSource.cacheKey]. It includes the
  /// file's size, so a file replaced on the server under the same id (a new
  /// encode, a fixed rip) is downloaded again instead of played from the old
  /// copy, which LRU eviction would otherwise keep for as long as it's
  /// played. Without a size (another server, or a song saved by an older
  /// version) it's the id alone.
  String keyFor(Song song) => song.size == null
      ? '$namespace|${song.id}'
      : '$namespace|${song.id}|${song.size}';

  /// The size, in pixels, of the cover art the player's media session shows
  /// (notification, lock screen, Bluetooth), see [artKeyFor].
  static const artSize = 300;

  /// The cache key of the cover art [coverArtId] at [artSize], see
  /// [AudioSource.artCacheKey]. The media session reads its artwork from the
  /// cache under it, so the artwork of a downloaded track shows offline too.
  String artKeyFor(String coverArtId) => '$namespace|art|$coverArtId@$artSize';

  /// Downloads the cover art [coverArtId] from [url] into the cache, unless
  /// it's there already (all tracks of an album share one). Returns whether
  /// it's cached.
  Future<bool> prefetchArt(String coverArtId, String url) async {
    try {
      await _cache.prefetch(artKeyFor(coverArtId), Uri.parse(url));
      return true;
    } on PrefetchCancelledException {
      return false;
    } catch (e) {
      _log.fine('Download of cover art $coverArtId failed', e);
      return false;
    }
  }

  /// Stops a download of the cover art [coverArtId] that is running or
  /// waiting, see [cancelDownload].
  Future<void> cancelArtDownload(String coverArtId) async {
    try {
      await _cache.cancelPrefetch(artKeyFor(coverArtId));
    } catch (e) {
      _log.warning('Could not cancel the download of cover art $coverArtId', e);
    }
  }

  /// Downloads [song] from [url] completely into the cache, unless it's
  /// there already. Returns whether it's completely cached; false also if
  /// [cancelDownload] stopped it.
  Future<bool> prefetch(Song song, String url) async {
    try {
      await _cache.prefetch(keyFor(song), Uri.parse(url));
      _log.fine('Cached ${song.id}');
      return true;
    } on PrefetchCancelledException {
      _log.fine('Download cancelled for ${song.id}');
      return false;
    } catch (e) {
      _log.warning('Download failed for ${song.id}', e);
      return false;
    }
  }

  /// Stops a download of [song] that is running or waiting for its turn,
  /// see [MediaCache.cancelPrefetch]. What it got so far stays cached.
  Future<void> cancelDownload(Song song) async {
    try {
      await _cache.cancelPrefetch(keyFor(song));
    } catch (e) {
      _log.warning('Could not cancel the download of ${song.id}', e);
    }
  }

  /// The first of [songs] that's completely cached, if any.
  Future<Song?> firstCached(List<Song> songs) async {
    if (songs.isEmpty) return null;
    final keys = [for (final song in songs) keyFor(song)];
    final cached = (await _cache.cachedKeys(keys)).toSet();
    for (final song in songs) {
      if (cached.contains(keyFor(song))) return song;
    }
    return null;
  }

  /// ReplayGain tags of [song], read from the cache without the network.
  /// Null if its start isn't cached.
  Future<ReplayGainData?> readReplayGain(Song song) async {
    final key = keyFor(song);
    var available = true;
    final data = await ReplayGainReader.readFromHead((length) async {
      final bytes = await _cache.readHead(key, length);
      if (bytes == null) available = false;
      return bytes;
    });
    return available ? data : null;
  }

  /// Fires when the device has a working internet connection again, so
  /// failed downloads can be retried, see [MediaCache.networkAvailable].
  Stream<void> get networkAvailable => _cache.networkAvailable;

  /// Size of cached audio in bytes (of all servers).
  Future<int> sizeInBytes() => _cache.sizeInBytes();

  /// Removes all cached audio.
  Future<void> clear() => _cache.clear();
}
