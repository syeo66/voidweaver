import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:voidweaver/services/replaygain_reader.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:voidweaver/services/upcoming_downloads.dart';

import '../test_helpers/fake_audio_cache.dart';
import '../test_helpers/mock_api.dart';
import '../test_helpers/mocks.mocks.dart';

void main() {
  late MockSubsonicApi api;
  late FakeAudioCache cache;
  late List<(int, ReplayGainData)> replayGains;
  late UpcomingDownloads downloads;

  Song song(String id, {double? gain}) => Song(
    id: id,
    title: 'Title $id',
    artist: 'Artist',
    album: 'Album',
    duration: 180,
    replayGainTrackGain: gain,
  );

  List<Song> songs(int count, {double? gain = -6}) => [
    for (var i = 0; i < count; i++) song('s$i', gain: gain),
  ];

  bool always() => true;

  /// Waits until the download of [id] has been attempted [times] times.
  Future<void> untilAttempted(String id, int times) async {
    for (var i = 0; i < 500 && (cache.attempts[id] ?? 0) < times; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(cache.attempts[id], greaterThanOrEqualTo(times));
  }

  setUp(() {
    api = newMockApi();
    when(api.getStreamUrl(any)).thenAnswer(
      (invocation) =>
          'https://music.test/stream?id=${invocation.positionalArguments.first}',
    );
    cache = FakeAudioCache();
    replayGains = [];
    downloads = UpcomingDownloads(
      audioCache: cache,
      api: api,
      retryDelay: const Duration(milliseconds: 1),
      onReplayGain: (playlist, index, data) => replayGains.add((index, data)),
    );
  });

  test('downloads the next tracks, nearest first, up to the limit', () async {
    await downloads.start(songs(10), 1, isCurrent: always);

    expect(cache.downloaded, ['s1', 's2', 's3']);
    expect(cache.urls.first, 'https://music.test/stream?id=s1');
  });

  test('stops at the end of the playlist', () async {
    await downloads.start(songs(3), 2, isCurrent: always);
    expect(cache.downloaded, ['s2']);

    await downloads.start(songs(3), 3, isCurrent: always);
    expect(cache.downloaded, ['s2']);
  });

  test('tries a failed download again until it succeeds', () async {
    cache.failing.add('s1');
    final run = downloads.start(songs(3), 1, isCurrent: always);
    await untilAttempted('s1', 2);
    cache.failing.clear();
    await run;

    expect(cache.attempts['s1'], greaterThan(1));
    expect(cache.downloaded, ['s1', 's2']);
  });

  test('gives up on a track after the retries and goes on', () async {
    cache.failing.add('s1');
    await downloads.start(songs(3), 1, isCurrent: always);

    expect(cache.attempts['s1'], UpcomingDownloads.maxRetries + 1);
    expect(cache.downloaded, ['s2']);
  });

  test('a newer run replaces the one in progress', () async {
    cache.failing.add('s1');
    final first = downloads.start(songs(5), 1, isCurrent: always);
    await untilAttempted('s1', 1);
    cache.failing.clear();
    final second = downloads.start(songs(5), 2, isCurrent: always);
    await Future.wait([first, second]);

    // The first run stopped at its failing track without going on
    expect(cache.downloaded, ['s2', 's3', 's4']);
  });

  test('cancel stops the run', () async {
    cache.failing.add('s1');
    final run = downloads.start(songs(5), 1, isCurrent: always);
    await untilAttempted('s1', 1);
    downloads.cancel();
    cache.failing.clear();
    await run;

    expect(cache.downloaded, isEmpty);
  });

  test('stops once isCurrent turns false', () async {
    var current = true;
    cache.failing.add('s1');
    final run = downloads.start(songs(5), 1, isCurrent: () => current);
    await untilAttempted('s1', 1);
    current = false;
    await run;

    expect(cache.downloaded, isEmpty);
  });

  test('sends nothing while the server rejects the credentials', () async {
    when(api.hasRejectedCredentials).thenReturn(true);

    await downloads.start(songs(3), 1, isCurrent: always);

    expect(cache.attempts, isEmpty);
  });

  test('reports ReplayGain read from a downloaded file', () async {
    cache.tags['s1'] = const ReplayGainData(trackGain: -7.5);

    await downloads.start(songs(3, gain: null), 1, isCurrent: always);

    expect(replayGains.map((r) => r.$1), [1, 2]);
    expect(replayGains.first.$2.trackGain, -7.5);
  });

  test('reads no ReplayGain for songs the server sent it for', () async {
    cache.tags['s1'] = const ReplayGainData(trackGain: -7.5);

    await downloads.start(songs(3), 1, isCurrent: always);

    expect(replayGains, isEmpty);
  });

  group('the download in progress', () {
    setUp(() => cache.gate = Completer<void>());

    Future<void> untilWaiting(String id) async {
      for (var i = 0; i < 500 && !cache.isWaiting(id); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(cache.isWaiting(id), isTrue);
    }

    test('is cancelled when another playlist starts', () async {
      final first = downloads.start(songs(5), 1, isCurrent: always);
      await untilWaiting('s1');
      final other = [for (var i = 0; i < 3; i++) song('o$i', gain: -6)];
      final second = downloads.start(other, 1, isCurrent: always);
      cache.gate!.complete();
      await Future.wait([first, second]);

      expect(cache.cancelled, ['s1']);
      expect(cache.downloaded, ['o1', 'o2']);
    });

    test('is cancelled when it is no longer among the next tracks', () async {
      final playlist = songs(10);
      final first = downloads.start(playlist, 1, isCurrent: always);
      await untilWaiting('s1');
      // A skip ahead
      final second = downloads.start(playlist, 6, isCurrent: always);
      cache.gate!.complete();
      await Future.wait([first, second]);

      expect(cache.cancelled, ['s1']);
      expect(cache.downloaded, ['s6', 's7', 's8']);
    });

    test('goes on when it is among the next tracks', () async {
      final playlist = songs(10);
      final first = downloads.start(playlist, 1, isCurrent: always);
      await untilWaiting('s1');
      // The next track started; s1 is still wanted
      final second = downloads.start(playlist, 1, isCurrent: always);
      cache.gate!.complete();
      await Future.wait([first, second]);

      expect(cache.cancelled, isEmpty);
      expect(cache.downloaded, ['s1', 's2', 's3']);
    });

    test('is cancelled by cancel', () async {
      final run = downloads.start(songs(5), 1, isCurrent: always);
      await untilWaiting('s1');
      downloads.cancel();
      cache.gate!.complete();
      await run;

      expect(cache.cancelled, ['s1']);
      expect(cache.downloaded, isEmpty);
    });

    test('a cancel with nothing in progress cancels nothing', () async {
      cache.gate = null;
      await downloads.start(songs(3), 1, isCurrent: always);
      downloads.cancel();
      await downloads.start(songs(3), 1, isCurrent: always);

      expect(cache.cancelled, isEmpty);
    });
  });
}
