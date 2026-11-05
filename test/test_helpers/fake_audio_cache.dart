import 'dart:async';

import 'package:voidweaver/models/subsonic_models.dart';
import 'package:voidweaver/services/audio_cache.dart';
import 'package:voidweaver/services/replaygain_reader.dart';

/// An [AudioCache] in memory, standing in for the player's cache. Keeps
/// songs by id, whatever their size.
class FakeAudioCache implements AudioCache {
  @override
  final String namespace;

  /// Song ids that are completely cached.
  final Set<String> cached = {};

  /// Whether downloads succeed.
  bool reachable = true;

  /// Song ids whose downloads fail, also while [reachable].
  final Set<String> failing = {};

  /// Every download attempt, by song id, including failed ones.
  final Map<String, int> attempts = {};

  /// When set, downloads wait for it to complete.
  Completer<void>? gate;

  /// Every song downloaded, in order.
  final List<String> downloaded = [];

  /// The URL of every download attempt, in order.
  final List<String> urls = [];

  /// Every song whose download was cancelled, in order.
  final List<String> cancelled = [];

  // Downloads waiting at [gate], by song id; cancelDownload() ends them
  final Map<String, List<Completer<void>>> _waiting = {};

  /// ReplayGain tags of cached songs, by song id.
  final Map<String, ReplayGainData> tags = {};

  FakeAudioCache({this.namespace = 'server'});

  /// Whether the content for an item's [cacheKey] is cached, see
  /// [MockAudioPlayer]'s `isCached`.
  bool isCachedKey(String? cacheKey) => cached.any(
    (id) =>
        cacheKey == '$namespace|$id' ||
        (cacheKey?.startsWith('$namespace|$id|') ?? false),
  );

  @override
  String keyFor(Song song) => song.size == null
      ? '$namespace|${song.id}'
      : '$namespace|${song.id}|${song.size}';

  @override
  Future<bool> prefetch(Song song, String url) async {
    final songId = song.id;
    final gate = this.gate;
    if (gate != null) {
      final cancel = Completer<void>();
      _waiting.putIfAbsent(songId, () => []).add(cancel);
      await Future.any([gate.future, cancel.future]);
      _waiting[songId]!.remove(cancel);
      if (cancel.isCompleted) return false;
    }
    if (cached.contains(songId)) return true;
    urls.add(url);
    attempts[songId] = (attempts[songId] ?? 0) + 1;
    if (!reachable || failing.contains(songId)) return false;
    downloaded.add(songId);
    cached.add(songId);
    return true;
  }

  /// Whether a download of [id] waits at [gate].
  bool isWaiting(String id) => _waiting[id]?.isNotEmpty ?? false;

  /// Ends the downloads of [song] waiting at [gate], which then return false.
  @override
  Future<void> cancelDownload(Song song) async {
    cancelled.add(song.id);
    for (final cancel in _waiting[song.id] ?? const <Completer<void>>[]) {
      if (!cancel.isCompleted) cancel.complete();
    }
  }

  @override
  Future<Song?> firstCached(List<Song> songs) async {
    for (final song in songs) {
      if (cached.contains(song.id)) return song;
    }
    return null;
  }

  @override
  Future<ReplayGainData?> readReplayGain(Song song) async =>
      cached.contains(song.id) ? tags[song.id] ?? const ReplayGainData() : null;

  @override
  Future<int> sizeInBytes() async => cached.length;

  @override
  Future<void> clear() async => cached.clear();
}
