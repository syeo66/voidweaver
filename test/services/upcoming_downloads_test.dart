import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:voidweaver/services/replaygain_reader.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:voidweaver/services/upcoming_downloads.dart';

import '../test_helpers/fake_audio_cache.dart';
import '../test_helpers/mock_api.dart';
import '../test_helpers/mocks.mocks.dart';
import '../test_helpers/waiting.dart';

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
  Future<void> untilAttempted(String id, int times) => pumpUntil(
    () => (cache.attempts[id] ?? 0) >= times,
    reason: '$times attempts to download $id',
  );

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

  group('when the network is back', () {
    test('starts a run again that gave up', () async {
      cache.reachable = false;
      await downloads.start(songs(5), 1, isCurrent: always);
      expect(cache.downloaded, isEmpty);

      cache.reachable = true;
      downloads.networkAvailable();
      await untilAttempted('s3', 1);
      await pumpEventQueue();

      expect(cache.downloaded, ['s1', 's2', 's3']);
    });

    test('retries right away instead of waiting for the next retry', () async {
      downloads = UpcomingDownloads(
        audioCache: cache,
        api: api,
        // Longer than the test may take
        retryDelay: const Duration(hours: 1),
        onReplayGain: (playlist, index, data) {},
      );
      cache.failing.add('s1');
      unawaited(downloads.start(songs(5), 1, isCurrent: always));
      await untilAttempted('s1', 1);

      cache.failing.clear();
      downloads.networkAvailable();
      await untilAttempted('s3', 1);
      await pumpEventQueue();

      expect(cache.downloaded, ['s1', 's2', 's3']);
      downloads.cancel();
    });

    test('keeps what the run got and goes on from there', () async {
      cache.failing.add('s2');
      await downloads.start(songs(5), 1, isCurrent: always);
      expect(cache.downloaded, ['s1', 's3']);

      cache.failing.clear();
      downloads.networkAvailable();
      await untilAttempted('s2', UpcomingDownloads.maxRetries + 2);
      await pumpEventQueue();

      expect(cache.downloaded, ['s1', 's3', 's2']);
      expect(cache.attempts['s1'], 1);
    });

    test('does nothing after a run that got everything', () async {
      await downloads.start(songs(5), 1, isCurrent: always);
      downloads.networkAvailable();
      await pumpEventQueue();

      expect(cache.attempts.values, everyElement(1));
    });

    test('does nothing once the run is no longer current', () async {
      var current = true;
      cache.reachable = false;
      await downloads.start(songs(5), 1, isCurrent: () => current);
      final attempts = cache.attempts['s1'];

      current = false;
      cache.reachable = true;
      downloads.networkAvailable();
      await pumpEventQueue();

      expect(cache.attempts['s1'], attempts);
      expect(cache.downloaded, isEmpty);
    });

    test('does nothing after cancel', () async {
      cache.reachable = false;
      await downloads.start(songs(5), 1, isCurrent: always);
      downloads.cancel();

      cache.reachable = true;
      downloads.networkAvailable();
      await pumpEventQueue();

      expect(cache.downloaded, isEmpty);
    });
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

    Future<void> untilWaiting(String id) =>
        pumpUntil(() => cache.isWaiting(id), reason: 'the download of $id');

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

  group('cover art', () {
    setUp(() {
      when(api.getCoverArtUrl(any, size: anyNamed('size'))).thenAnswer(
        (invocation) =>
            'https://music.test/getCoverArt?id=${invocation.positionalArguments.first}'
            '&size=${invocation.namedArguments[#size]}',
      );
    });

    List<Song> withArt(List<Song> songs) => [
      for (final (i, s) in songs.indexed)
        s.copyWith(coverArt: i < 2 ? 'al-1' : 'al-2'),
    ];

    test(
      'is downloaded with each track, at the size the session shows',
      () async {
        await downloads.start(withArt(songs(10)), 1, isCurrent: always);

        expect(cache.downloaded, ['s1', 's2', 's3']);
        expect(cache.artDownloaded, ['al-1', 'al-2', 'al-2']);
        verify(api.getCoverArtUrl('al-1', size: 300));
      },
    );

    test('isn\'t downloaded for a track that failed', () async {
      cache.failing.add('s1');
      await downloads.start(withArt(songs(2)), 1, isCurrent: always);

      expect(cache.artDownloaded, isEmpty);
    });

    test('a download in progress is cancelled when the downloads start '
        'again', () async {
      cache.artGate = Completer<void>();
      final first = downloads.start(withArt(songs(5)), 1, isCurrent: always);
      await pumpUntil(() => cache.isArtWaiting('al-1'), reason: 'al-1');
      // Another queue started
      final second = downloads.start(
        [song('x1').copyWith(coverArt: 'al-9')],
        0,
        isCurrent: always,
      );
      expect(cache.artCancelled, ['al-1']);
      cache.artGate!.complete();
      await Future.wait([first, second]);

      // The first run stopped; the second got its cover
      expect(cache.downloaded, ['s1', 'x1']);
      expect(cache.artDownloaded, ['al-9']);
    });

    test('a download in progress is cancelled by cancel', () async {
      cache.artGate = Completer<void>();
      final run = downloads.start(withArt(songs(5)), 1, isCurrent: always);
      await pumpUntil(() => cache.isArtWaiting('al-1'), reason: 'al-1');
      downloads.cancel();
      cache.artGate!.complete();
      await run;

      expect(cache.artCancelled, ['al-1']);
      expect(cache.downloaded, ['s1']);
      expect(cache.artDownloaded, isEmpty);
    });

    test('isn\'t downloaded once the run is superseded', () async {
      var wanted = true;
      // The track's download finishes after its playlist was replaced
      cache.gate = Completer<void>();
      final run = downloads.start(
        withArt(songs(3)),
        1,
        isCurrent: () => wanted,
      );
      await pumpUntil(() => cache.isWaiting('s1'), reason: 's1 waiting');
      wanted = false;
      cache.gate!.complete();
      await run;

      expect(cache.downloaded, ['s1']);
      expect(cache.artDownloaded, isEmpty);
    });

    test('isn\'t downloaded while the credentials are rejected', () async {
      final playlist = withArt(songs(3));
      cache.gate = Completer<void>();
      final run = downloads.start(playlist, 1, isCurrent: always);
      await pumpUntil(() => cache.isWaiting('s1'), reason: 's1 waiting');
      when(api.hasRejectedCredentials).thenReturn(true);
      cache.gate!.complete();
      await run;

      expect(cache.downloaded, ['s1']);
      expect(cache.artDownloaded, isEmpty);
    });
  });
}
