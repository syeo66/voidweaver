import 'dart:async';

import 'package:voidweaver/services/audio_cache.dart';
import 'package:voidweaver/services/replaygain_reader.dart';

/// An [AudioCache] in memory, standing in for the player's cache.
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

  /// ReplayGain tags of cached songs, by song id.
  final Map<String, ReplayGainData> tags = {};

  FakeAudioCache({this.namespace = 'server'});

  /// Whether the content for an item's [cacheKey] is cached, see
  /// [MockAudioPlayer]'s `isCached`.
  bool isCachedKey(String? cacheKey) =>
      cached.any((id) => keyFor(id) == cacheKey);

  @override
  String keyFor(String songId) => '$namespace|$songId';

  @override
  Future<bool> prefetch(String songId, String url) async {
    await gate?.future;
    if (cached.contains(songId)) return true;
    attempts[songId] = (attempts[songId] ?? 0) + 1;
    if (!reachable || failing.contains(songId)) return false;
    downloaded.add(songId);
    cached.add(songId);
    return true;
  }

  @override
  Future<String?> firstCached(List<String> songIds) async {
    for (final id in songIds) {
      if (cached.contains(id)) return id;
    }
    return null;
  }

  @override
  Future<ReplayGainData?> readReplayGain(String songId) async =>
      cached.contains(songId) ? tags[songId] ?? const ReplayGainData() : null;

  @override
  Future<int> sizeInBytes() async => cached.length;

  @override
  Future<void> clear() async => cached.clear();
}
