import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/services/audio_cache.dart';
import 'package:voidweaver_player/voidweaver_player.dart';

/// The player's cache, in memory: content by key.
class FakeMediaCache implements MediaCache {
  final Map<String, Uint8List> content = {};
  bool reachable = true;
  final List<String> prefetched = [];

  @override
  Future<void> prefetch(String key, Uri uri) async {
    if (!reachable) throw Exception('offline');
    prefetched.add(key);
    content[key] = Uint8List(4);
  }

  @override
  Future<List<String>> cachedKeys(List<String> keys) async =>
      keys.where(content.containsKey).toList();

  @override
  Future<Uint8List?> readHead(String key, int length) async {
    final bytes = content[key];
    if (bytes == null) return null;
    return bytes.sublist(0, length.clamp(0, bytes.length));
  }

  @override
  Future<int> sizeInBytes() async =>
      content.values.fold<int>(0, (sum, bytes) => sum + bytes.length);

  @override
  Future<void> clear() async => content.clear();
}

void main() {
  late FakeMediaCache mediaCache;
  late AudioCache cache;

  setUp(() {
    mediaCache = FakeMediaCache();
    cache = AudioCache(namespace: 'https://a.test', cache: mediaCache);
  });

  test('keys entries by server and song', () async {
    final other = AudioCache(namespace: 'https://b.test', cache: mediaCache);

    await cache.prefetch('s1', 'https://a.test/rest/stream?id=s1');

    expect(mediaCache.prefetched, ['https://a.test|s1']);
    expect(await cache.firstCached(['s1']), 's1');
    expect(await other.firstCached(['s1']), isNull);
  });

  test('a failed download reports false', () async {
    mediaCache.reachable = false;

    expect(await cache.prefetch('s1', 'https://a.test/rest/stream?id=s1'),
        isFalse);
  });

  test('firstCached keeps the order of the songs asked for', () async {
    await cache.prefetch('s3', 'url');
    await cache.prefetch('s2', 'url');

    expect(await cache.firstCached(['s1', 's2', 's3']), 's2');
    expect(await cache.firstCached(['s1']), isNull);
    expect(await cache.firstCached([]), isNull);
  });

  test('ReplayGain is read from the cached start of the song', () async {
    mediaCache.content['https://a.test|s1'] = Uint8List.fromList(
        'OggS....OpusTags....R128_TRACK_GAIN=-2304'.codeUnits);

    final data = await cache.readReplayGain('s1');

    expect(data?.trackGain, closeTo(-4.0, 1e-9));
    expect(await cache.readReplayGain('s2'), isNull);
  });
}
