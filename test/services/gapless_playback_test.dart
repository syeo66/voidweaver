import 'dart:async';
import 'dart:io';

import 'package:voidweaver_player/voidweaver_player.dart'
    show ProcessingState, SystemCommandType;
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/network_errors.dart';
import 'package:voidweaver/services/replaygain_reader.dart';
import 'package:voidweaver/services/scrobble_queue.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/settings_service.dart';
import 'package:voidweaver/services/subsonic_api.dart';

import '../test_helpers/fake_audio_cache.dart';
import '../test_helpers/mock_audio_player.dart';
import '../test_helpers/mock_api.dart';
import '../test_helpers/mocks.mocks.dart';

void main() {
  // Skips within this window of the previous one are ignored by the service
  const pastSkipDebounce = Duration(milliseconds: 250);

  late MockSubsonicApi mockApi;
  late MockSettingsService mockSettings;
  late MockAudioPlayer player;
  late FakeAudioCache cache;
  late AudioPlayerService service;

  String urlFor(String id) => 'https://music.test/rest/stream?id=$id';

  // Each song's track gain maps to a distinct volume, see setUp
  Song song(String id, {double gain = -6.0}) => Song(
    id: id,
    title: 'Title $id',
    artist: 'Artist',
    album: 'Album',
    duration: 180,
    replayGainTrackGain: gain,
  );

  Album album(List<Song> songs) =>
      Album(id: 'album1', name: 'Album', artist: 'Artist', songs: songs);

  Album albumOf(int count) =>
      album([for (var i = 1; i <= count; i++) song('s$i')]);

  // A song the server sends no ReplayGain for: its tags are read from the
  // file before it starts, through mockApi.readReplayGain
  Song unread(String id) => Song(
    id: id,
    title: 'Title $id',
    artist: 'Artist',
    album: 'Album',
    duration: 180,
  );

  /// Waits until [condition] holds, failing after a second.
  Future<void> until(bool Function() condition, String description) async {
    for (var i = 0; i < 100; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Timed out waiting until $description');
  }

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});

    mockApi = newMockApi();
    mockSettings = MockSettingsService();
    cache = FakeAudioCache();
    player = MockAudioPlayer(isCached: cache.isCachedKey);

    when(mockSettings.replayGainMode).thenReturn(ReplayGainMode.track);
    when(mockSettings.replayGainPreamp).thenReturn(0.0);
    when(mockSettings.replayGainFallbackGain).thenReturn(0.0);
    when(mockSettings.replayGainPreventClipping).thenReturn(true);
    when(mockSettings.scrobbleMinPlayTimeMinutes).thenReturn(4.0);
    when(mockSettings.scrobbleThresholdPercent).thenReturn(50.0);
    when(
      mockSettings.calculateVolumeAdjustment(
        trackGain: anyNamed('trackGain'),
        albumGain: anyNamed('albumGain'),
        trackPeak: anyNamed('trackPeak'),
        albumPeak: anyNamed('albumPeak'),
        fromAlbum: anyNamed('fromAlbum'),
      ),
    ).thenAnswer((invocation) {
      final gain = invocation.namedArguments[#trackGain] as double?;
      return gain == -6.0 ? 0.5 : 0.7;
    });

    when(mockApi.getStreamUrl(any)).thenAnswer(
      (invocation) => urlFor(invocation.positionalArguments.first as String),
    );
    when(mockApi.readReplayGain(any))
        .thenAnswer((_) async => const ReplayGainData());

    service = AudioPlayerService(
      mockApi,
      mockSettings,
      audioPlayer: player,
      audioCache: cache,
      downloadRetryDelay: const Duration(milliseconds: 5),
    );
  });

  tearDown(() async {
    service.dispose();
    await player.dispose();
  });

  group('queue', () {
    test('hands the whole playlist to the player', () async {
      cache.reachable = false;

      await service.playAlbum(albumOf(3));

      expect(player.sequenceSources, [
        urlFor('s1'),
        urlFor('s2'),
        urlFor('s3'),
      ]);
      expect(player.currentIndex, 0);
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('identifies each track in the cache by server and song', () async {
      cache.reachable = false;
      await service.playAlbum(albumOf(2));

      expect(
        [for (final s in player.sequence) s.cacheKey],
        ['server|s1', 'server|s2'],
      );
    });

    test('downloads the next three tracks, nearest first', () async {
      await service.playAlbum(albumOf(5));
      await until(() => cache.downloaded.length == 3, 'three downloads');

      expect(cache.downloaded, ['s2', 's3', 's4']);
      // Downloads go to the cache, which the player reads; the queue stays
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('tries a failed download again', () async {
      cache.reachable = false;
      await service.playAlbum(albumOf(3));
      await until(() => (cache.attempts['s2'] ?? 0) >= 2, 'a second attempt');

      // The network is back
      cache.reachable = true;
      await until(() => cache.downloaded.length == 2, 'both downloads');

      expect(cache.downloaded, ['s2', 's3']);
    });

    test('moves on to the next download after a few retries', () async {
      cache.failing.add('s2');
      await service.playAlbum(albumOf(4));
      await until(() => cache.downloaded.length == 2, 'the later downloads');

      expect(cache.downloaded, ['s3', 's4']);
      expect(cache.attempts['s2'], 6);
    });

    test('downloads again when the network is back after the retries '
        'gave up', () async {
      cache.reachable = false;
      await service.playAlbum(albumOf(3));
      await until(
        () => (cache.attempts['s3'] ?? 0) == 6,
        'all retries of both tracks',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(cache.downloaded, isEmpty);

      cache.reachable = true;
      cache.simulateNetworkAvailable();
      await until(() => cache.downloaded.length == 2, 'both downloads');

      expect(cache.downloaded, ['s2', 's3']);
    });

    test('stops retrying once another track starts', () async {
      cache.failing.add('s3');
      await service.playAlbum(albumOf(5));
      await until(() => (cache.attempts['s3'] ?? 0) >= 2, 'a retry');

      final before = cache.attempts['s3']!;
      player.simulateTrackTransition();
      await until(() => service.currentIndex == 1, 'the service follows');
      await until(() => cache.downloaded.contains('s5'), 's5 is downloaded');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Only the new track's downloads try s3: a first attempt, five retries
      expect(cache.attempts['s3'], before + 6);
    });

    test('stops retrying while the server rejects the credentials', () async {
      cache.reachable = false;
      await service.playAlbum(albumOf(3));
      await until(() => (cache.attempts['s2'] ?? 0) >= 1, 'a first attempt');

      // E.g. the "now playing" of the track was refused
      when(mockApi.hasRejectedCredentials).thenReturn(true);
      final before = cache.attempts['s2']!;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // At most the attempt that was already under way
      expect(cache.attempts['s2'], lessThanOrEqualTo(before + 1));
      expect(cache.attempts['s3'], isNull);

      // The new password restarts them
      when(mockApi.hasRejectedCredentials).thenReturn(false);
      cache.reachable = true;
      service.credentialsChanged();
      await until(() => cache.downloaded.length == 2, 'both downloads');
      expect(cache.downloaded, ['s2', 's3']);
    });
  });

  group('starting a queue that can\'t be fetched', () {
    Future<void> playing(Album playingAlbum) async {
      await service.playAlbum(playingAlbum);
      await until(
        () => service.playbackState == PlaybackState.playing,
        'the album plays',
      );
    }

    test('keeps the album playing when random songs fail', () async {
      final current = albumOf(3);
      await playing(current);
      when(mockApi.getRandomSongs(any))
          .thenThrow(const SocketException('offline'));

      await expectLater(
        service.playRandomSongs(),
        throwsA(isA<SocketException>()),
      );

      expect(service.playbackState, PlaybackState.playing);
      expect(player.playing, isTrue);
      expect(service.playlist.map((s) => s.id), ['s1', 's2', 's3']);
      expect(service.currentSong?.id, 's1');
      expect(player.sequenceSources, [
        urlFor('s1'),
        urlFor('s2'),
        urlFor('s3'),
      ]);
    });

    test('keeps the album playing when another album fails', () async {
      await playing(albumOf(2));
      when(mockApi.getAlbum('other'))
          .thenThrow(const SocketException('offline'));

      await expectLater(
        service.playAlbum(
          Album(id: 'other', name: 'Other', artist: 'Artist', songs: []),
        ),
        throwsA(isA<SocketException>()),
      );

      expect(service.playbackState, PlaybackState.playing);
      expect(player.playing, isTrue);
      expect(service.playlist.map((s) => s.id), ['s1', 's2']);
    });

    test('keeps a paused album paused', () async {
      await playing(albumOf(2));
      await service.pause();
      await until(
        () => service.playbackState == PlaybackState.paused,
        'the pause',
      );
      when(mockApi.getRandomSongs(any)).thenAnswer((_) async => <Song>[]);

      await expectLater(
        service.playRandomSongs(),
        throwsA(isA<UserFacingException>()),
      );

      expect(service.playbackState, PlaybackState.paused);
      expect(player.playing, isFalse);
    });

    test('shows loading while fetching', () async {
      await playing(albumOf(2));
      final songs = Completer<List<Song>>();
      when(mockApi.getRandomSongs(any)).thenAnswer((_) => songs.future);

      final start = service.playRandomSongs();
      expect(service.playbackState, PlaybackState.loading);

      songs.completeError(const SocketException('offline'));
      await expectLater(start, throwsA(isA<SocketException>()));
      expect(service.playbackState, PlaybackState.playing);
    });

    test('keeps a state the player reported meanwhile', () async {
      await playing(albumOf(2));
      final songs = Completer<List<Song>>();
      when(mockApi.getRandomSongs(any)).thenAnswer((_) => songs.future);

      final start = service.playRandomSongs();
      // Paused from the notification while the request runs
      await service.pause();
      await until(
        () => service.playbackState == PlaybackState.paused,
        'the pause',
      );

      songs.completeError(const SocketException('offline'));
      await expectLater(start, throwsA(isA<SocketException>()));
      expect(service.playbackState, PlaybackState.paused);
    });

    test('lets the last of two starts take over', () async {
      cache.reachable = false;
      final slow = Completer<List<Song>>();
      when(mockApi.getRandomSongs(any)).thenAnswer((_) => slow.future);

      final random = service.playRandomSongs();
      await service.playAlbum(albumOf(2));
      slow.complete([song('r1'), song('r2'), song('r3')]);
      await random;

      expect(service.playlist.map((s) => s.id), ['s1', 's2']);
      expect(player.sequenceSources, [urlFor('s1'), urlFor('s2')]);
    });
  });

  group('ReplayGain', () {
    test('gives every track its own gain before playback starts', () async {
      cache.reachable = false;
      await service.playAlbum(album([song('s1'), song('s2', gain: -3.0)]));

      expect(player.gainOfSource(urlFor('s1')), 0.5);
      expect(player.gainOfSource(urlFor('s2')), 0.7);
    });

    test('leaves the gains alone when the player moves on', () async {
      cache.reachable = false;
      await service.playAlbum(album([song('s1'), song('s2', gain: -3.0)]));

      player.simulateTrackTransition();
      await until(() => service.currentSong?.id == 's2', 'the service follows');

      // A change at the transition would apply to whatever is playing then
      expect(player.gainOfSource(urlFor('s1')), 0.5);
      expect(player.gainOfSource(urlFor('s2')), 0.7);
    });

    test('a gain read from a downloaded track applies to it', () async {
      final untagged = Song(
        id: 's2',
        title: 'Title s2',
        artist: 'Artist',
        album: 'Album',
      );
      cache.tags['s2'] = const ReplayGainData(trackGain: -6.0);
      await service.playAlbum(album([song('s1', gain: -3.0), untagged]));
      expect(player.gainOfSource(urlFor('s2')), 0.7);

      await until(
        () => player.gainOfSource(urlFor('s2')) == 0.5,
        'the gain is read from the cache',
      );
      expect(player.gainOfSource(urlFor('s1')), 0.7);
    });

    test(
      'the start track gets a gain read from its file before it plays',
      () async {
        cache.reachable = false;
        final untagged = Song(
          id: 's1',
          title: 'Title s1',
          artist: 'Artist',
          album: 'Album',
        );
        when(mockApi.readReplayGain('s1'))
            .thenAnswer((_) async => const ReplayGainData(trackGain: -6.0));

        await service.playAlbum(album([untagged]));

        expect(player.gainOfSource(urlFor('s1')), 0.5);
        verify(mockApi.readReplayGain('s1')).called(1);
      },
    );

    test('changed settings apply to every track', () async {
      cache.reachable = false;
      await service.playAlbum(albumOf(3));
      when(
        mockSettings.calculateVolumeAdjustment(
          trackGain: anyNamed('trackGain'),
          albumGain: anyNamed('albumGain'),
          trackPeak: anyNamed('trackPeak'),
          albumPeak: anyNamed('albumPeak'),
          fromAlbum: anyNamed('fromAlbum'),
        ),
      ).thenReturn(1.4);

      await service.refreshReplayGainVolume();

      for (final id in ['s1', 's2', 's3']) {
        expect(player.gainOfSource(urlFor(id)), 1.4);
      }
    });

    test('tells the settings whether the queue is an album', () async {
      cache.reachable = false;
      when(
        mockSettings.calculateVolumeAdjustment(
          trackGain: anyNamed('trackGain'),
          albumGain: anyNamed('albumGain'),
          trackPeak: anyNamed('trackPeak'),
          albumPeak: anyNamed('albumPeak'),
          fromAlbum: anyNamed('fromAlbum'),
        ),
      ).thenAnswer(
        (invocation) =>
            invocation.namedArguments[#fromAlbum] == true ? 0.3 : 0.9,
      );

      await service.playAlbum(albumOf(2));
      expect(player.gainOfSource(urlFor('s1')), 0.3);

      when(mockApi.getRandomSongs(any))
          .thenAnswer((_) async => [song('r1'), song('r2')]);
      await service.playRandomSongs(2);
      expect(player.gainOfSource(urlFor('r1')), 0.9);

      await service.playSong(song('x1'));
      expect(player.gainOfSource(urlFor('x1')), 0.9);
    });
  });

  group('transition', () {
    test('follows the player to the next track without reloading', () async {
      await service.playAlbum(albumOf(3));

      player.simulateTrackTransition();
      await until(() => service.currentSong?.id == 's2', 'the service follows');

      expect(service.currentIndex, 1);
      expect(service.totalDuration, const Duration(minutes: 4));
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('downloads further ahead after moving on', () async {
      await service.playAlbum(albumOf(5));
      await until(() => cache.downloaded.length == 3, 'three downloads');

      player.simulateTrackTransition();
      await until(() => cache.downloaded.contains('s5'), 's5 is downloaded');

      expect(cache.downloaded, ['s2', 's3', 's4', 's5']);
      expect(player.currentIndex, 1);
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('ignores repeated and late index events', () async {
      await service.playAlbum(albumOf(4));
      player.simulateTrackTransition();
      await until(() => service.currentSong?.id == 's2', 'the service follows');

      for (final index in [1, 0, 1, 1]) {
        player.simulateIndexEvent(index);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(service.currentSong?.id, 's2');
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('scrobbles the finished track and reports the new one', () async {
      await service.playAlbum(albumOf(2));

      player.simulateTrackTransition();
      // The scrobble queue sends requests asynchronously, 100 ms apart
      await Future<void>.delayed(const Duration(milliseconds: 500));

      verify(mockApi.scrobbleSubmission('s1', playedAt: anyNamed('playedAt')))
          .called(1);
      verify(mockApi.scrobbleNowPlaying('s2')).called(1);
    });

    test('pauses at the start of the last track after it ends', () async {
      await service.playAlbum(albumOf(2));
      player.simulateTrackTransition();
      await until(() => service.currentSong?.id == 's2', 'the service follows');

      player.simulateCompletion();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(service.currentIndex, 1);
      expect(service.playbackState, PlaybackState.paused);
      expect(player.playing, isFalse);
      expect(player.position, Duration.zero);
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test(
      'the end of the queue arriving during a skip back is not the target\'s',
      () async {
        // s1's tags couldn't be read at the start, so Previous reads them
        // again (a file read without tags wouldn't be, see
        // ReplayGainResolver.readMissing)
        when(mockApi.readReplayGain('s1'))
            .thenAnswer((_) async => const ReplayGainData.unavailable());
        await service.playAlbum(album([unread('s1'), song('s2')]));
        player.simulateTrackTransition();
        await until(
          () => service.currentSong?.id == 's2',
          'the service follows',
        );
        // s1 is scrobbled for the transition; only what follows counts here
        await Future<void>.delayed(const Duration(milliseconds: 500));
        clearInteractions(mockApi);
        // Previous reads s1's tags before it seeks back, so the player is
        // still on s2 when the end of s2 (the last track) arrives
        final gainRead = Completer<ReplayGainData>();
        when(mockApi.readReplayGain('s1')).thenAnswer((_) => gainRead.future);

        final skipping = service.previous();
        await pumpEventQueue();
        player.simulateCompletion();
        await pumpEventQueue();
        gainRead.complete(const ReplayGainData());
        await skipping;
        // The scrobble queue sends requests asynchronously, 100 ms apart
        await Future<void>.delayed(const Duration(milliseconds: 500));

        // s1 wasn't heard yet: the end belonged to s2
        verifyNever(
          mockApi.scrobbleSubmission('s1', playedAt: anyNamed('playedAt')),
        );
        expect(service.currentSong?.id, 's1');
        expect(player.currentIndex, 0);
        expect(player.playing, isTrue);
        expect(service.playbackState, PlaybackState.playing);
      },
    );

    test('play after the end replays the last track as a new play', () async {
      await service.playAlbum(albumOf(1));
      player.simulateCompletion();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      verify(mockApi.scrobbleSubmission('s1', playedAt: anyNamed('playedAt')))
          .called(1);

      await service.play();
      expect(player.playing, isTrue);
      player.simulateCompletion();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      verify(mockApi.scrobbleSubmission('s1', playedAt: anyNamed('playedAt')))
          .called(1);
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('does not cut a track short near its end', () async {
      await service.playAlbum(albumOf(3));

      player.simulatePositionChange(
        const Duration(minutes: 2, seconds: 59, milliseconds: 800),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(service.currentIndex, 0);
      expect(player.loadedSources, [urlFor('s1')]);
    });
  });

  group('offline', () {
    test('a downloaded track plays although its stream fails', () async {
      cache.cached.add('s2');
      cache.reachable = false;
      await service.playAlbum(albumOf(3));
      player.failingUrls.add(urlFor('s2'));

      player.simulateTrackTransition();
      await until(() => service.currentIndex == 1, 'the service follows');
      await pumpEventQueue();

      expect(service.playbackState, PlaybackState.playing);
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test(
      'continues at the next downloaded track when the next one fails',
      () async {
        cache.cached.add('s3');
        cache.reachable = false;
        await service.playAlbum(albumOf(3));
        player.failingUrls.add(urlFor('s2'));

        player.simulateTrackTransition();
        await until(
          () => service.currentIndex == 2,
          'playback continues at s3',
        );

        expect(player.loadedSources.last, urlFor('s3'));
        expect(service.playbackState, PlaybackState.playing);
      },
    );

    test(
      'continues at the next downloaded track when a stream breaks off',
      () async {
        cache.cached.add('s3');
        cache.reachable = false;
        await service.playAlbum(albumOf(3));

        player.simulateLoadError();
        await until(
          () => service.currentIndex == 2,
          'playback continues at s3',
        );

        expect(player.loadedSources.last, urlFor('s3'));
      },
    );

    test(
      'stops when nothing ahead is downloaded, and play() tries again',
      () async {
        cache.reachable = false;
        await service.playAlbum(albumOf(2));
        player.failingUrls.add(urlFor('s2'));

        player.simulateTrackTransition();
        await until(
          () => service.playbackState == PlaybackState.stopped,
          'playback stops',
        );
        expect(service.currentSong?.id, 's2');

        player.failingUrls.clear();
        await service.play();
        await until(
          () => service.playbackState == PlaybackState.playing,
          'playback resumes',
        );

        expect(player.loadedSources.last, urlFor('s2'));
        expect(service.currentIndex, 1);
      },
    );
  });

  group('playback errors', () {
    late List<String> errors;

    setUp(() {
      errors = [];
      service.playbackErrors.listen(errors.add);
      cache.reachable = false;
    });

    test(
      'reports a track that fails with nothing downloaded after it',
      () async {
        await service.playAlbum(albumOf(2));
        player.failingUrls.add(urlFor('s2'));

        player.simulateTrackTransition();
        await until(() => errors.isNotEmpty, 'the failure is reported');

        expect(errors, [startsWith('Could not play "Title s2"')]);
      },
    );

    test('reports a play that fails', () async {
      await service.playAlbum(albumOf(2));
      player.failingUrls.add(urlFor('s2'));
      player.simulateTrackTransition();
      await until(() => errors.length == 1, 'the failure is reported');

      await service.play();
      await pumpEventQueue();

      expect(errors, hasLength(2));
      expect(errors.last, startsWith('Could not play "Title s2"'));
      expect(service.playbackState, PlaybackState.stopped);
    });

    test('reports a skip to a track that fails', () async {
      await service.playAlbum(albumOf(2));
      player.failingUrls.add(urlFor('s2'));

      await service.next();
      await until(() => errors.isNotEmpty, 'the failure is reported');

      expect(errors, [startsWith('Could not play "Title s2"')]);
    });

    test('does not report continuing at a downloaded track', () async {
      cache.cached.add('s3');
      await service.playAlbum(albumOf(3));
      player.failingUrls.add(urlFor('s2'));

      player.simulateTrackTransition();
      await until(() => service.currentIndex == 2, 'playback continues');
      await pumpEventQueue();

      expect(errors, isEmpty);
    });

    test('ignores an error of the queue a new album replaces', () async {
      await service.playAlbum(albumOf(2));
      final gainRead = Completer<ReplayGainData>();
      when(mockApi.readReplayGain('n1')).thenAnswer((_) => gainRead.future);

      // The new album reads its first track's tags before it replaces the
      // player's sequence; meanwhile the old track breaks off
      final starting = service.playAlbum(
        Album(
          id: 'album2',
          name: 'New',
          artist: 'Artist',
          songs: [unread('n1'), song('n2')],
        ),
      );
      await pumpEventQueue();
      player.simulateLoadError();
      await pumpEventQueue();
      gainRead.complete(const ReplayGainData());
      await starting;
      await pumpEventQueue();

      expect(errors, isEmpty);
      expect(service.currentSong?.id, 'n1');
      expect(player.playing, isTrue);
      expect(service.playbackState, PlaybackState.playing);
    });

    test(
      'ignores an error held during a skip once a new album replaced the queue',
      () async {
        await service.playAlbum(album([song('s1'), unread('s2'), song('s3')]));
        await Future<void>.delayed(pastSkipDebounce);
        final gainRead = Completer<ReplayGainData>();
        when(mockApi.readReplayGain('s2')).thenAnswer((_) => gainRead.future);

        // The skip reads its target's tags, so it's still running when the
        // old track breaks off: the error is held until it's done. By then
        // another album has replaced the queue.
        final skipping = service.next();
        await pumpEventQueue();
        player.simulateLoadError();
        final starting = service.playAlbum(
          Album(
            id: 'album2',
            name: 'New',
            artist: 'Artist',
            songs: [song('n1'), song('n2')],
          ),
        );
        await pumpEventQueue();
        gainRead.complete(const ReplayGainData());
        await skipping;
        await starting;
        await pumpEventQueue();

        expect(errors, isEmpty);
        expect(service.currentSong?.id, 'n1');
        expect(player.currentIndex, 0);
        expect(player.playing, isTrue);
        expect(service.playbackState, PlaybackState.playing);
      },
    );

    test('an error held during a skip doesn\'t reload a new album after a '
        'password change', () async {
      await service.playAlbum(album([song('s1'), unread('s2'), song('s3')]));
      await Future<void>.delayed(pastSkipDebounce);
      final gainRead = Completer<ReplayGainData>();
      when(mockApi.readReplayGain('s2')).thenAnswer((_) => gainRead.future);

      // The skip reads its target's tags, so it's still running when the
      // old track breaks off: the error is held until it's done. By then
      // another album has replaced the queue.
      // The stream URLs carry an old password: an error loads the queue
      // again where it failed, which must not be the new album
      service.credentialsChanged();
      final skipping = service.next();
      await pumpEventQueue();
      player.simulateLoadError();
      final starting = service.playAlbum(
        Album(
          id: 'album2',
          name: 'New',
          artist: 'Artist',
          songs: [song('n1'), song('n2')],
        ),
      );
      await pumpEventQueue();
      gainRead.complete(const ReplayGainData());
      await skipping;
      await starting;
      await pumpEventQueue();

      expect(errors, isEmpty);
      expect(
        player.loadedSources.where((url) => url == urlFor('n1')),
        hasLength(1),
      );
      expect(service.currentSong?.id, 'n1');
      expect(player.currentIndex, 0);
      expect(player.playing, isTrue);
      expect(service.playbackState, PlaybackState.playing);
    });

    test(
      'a seek right after a track fails doesn\'t hide the failure',
      () async {
        await service.playAlbum(albumOf(1));
        player.simulateBuffering();

        player.simulateLoadError();
        // The service gets the error and looks for a downloaded track to go
        // on at; the user drags the seek bar meanwhile
        await Future<void>.value();
        unawaited(service.seekTo(const Duration(seconds: 25)));
        await pumpEventQueue();

        expect(errors, [startsWith('Could not play "Title s1"')]);
        expect(service.playbackState, PlaybackState.stopped);
      },
    );

    test('a pause while looking for a downloaded track to go on at holds and '
        'reports the failure', () async {
      cache.cached.add('s3');
      await service.playAlbum(albumOf(3));
      cache.lookupGate = Completer();

      player.simulateLoadError();
      await pumpEventQueue();
      // The service looks into the cache for a track to go on at
      await service.pause();
      cache.lookupGate!.complete();
      await pumpEventQueue();

      // As for a track failing while paused: it stops on it, and the
      // message is expected (s1 did fail)
      expect(player.playing, isFalse);
      expect(service.currentSong?.id, 's1');
      expect(service.playbackState, PlaybackState.stopped);
      expect(errors, [startsWith('Could not play "Title s1"')]);
    });

    test('an error held while a new album loads, with a seek queued behind the '
        'load, leaves the new album as it is', () async {
      await service.playAlbum(album([song('s1'), unread('s2'), song('s3')]));
      await Future<void>.delayed(pastSkipDebounce);
      final gainRead = Completer<ReplayGainData>();
      when(mockApi.readReplayGain('s2')).thenAnswer((_) => gainRead.future);

      // The skip reads its target's tags; the old track breaks off
      // meanwhile, so its error is held until the operations are done
      final skipping = service.next();
      await pumpEventQueue();
      player.simulateLoadError();
      player.loadGate = Completer();
      final starting = service.playAlbum(
        Album(
          id: 'album2',
          name: 'New',
          artist: 'Artist',
          songs: [song('n1'), song('n2')],
        ),
      );
      await pumpEventQueue();
      gainRead.complete(const ReplayGainData());
      await pumpEventQueue();
      // The new album's load is running: a seek queues behind it
      final seeking = service.seekTo(const Duration(seconds: 60));
      player.loadGate!.complete();
      await skipping;
      await starting;
      await seeking;
      await pumpEventQueue();
      expect(service.currentSong?.id, 'n1');
      expect(player.playing, isTrue);

      // Pause and Play resume the new album where it is, without loading
      // it again
      await service.pause();
      final loads = player.loadedSources.length;
      await service.play();
      await pumpEventQueue();
      expect(player.loadedSources, hasLength(loads));
      expect(player.position, const Duration(seconds: 60));
      expect(player.playing, isTrue);
      expect(errors, isEmpty);
    });

    test('leaves a failed start to its caller', () async {
      player.failingUrls.add(urlFor('s1'));

      await expectLater(service.playAlbum(albumOf(1)), throwsA(anything));
      await pumpEventQueue();

      expect(errors, isEmpty);
    });
  });

  group('scrobbles', () {
    test('a scrobble that failed is sent when the network is back', () async {
      var attempts = 0;
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {
            if (attempts++ == 0) throw Exception('offline');
          });
      // Retries far apart: only the network event can send it again
      final queue = ScrobbleQueue(
        mockApi,
        initialRetryDelay: const Duration(minutes: 5),
      );
      final scrobbling = AudioPlayerService(
        mockApi,
        mockSettings,
        audioPlayer: MockAudioPlayer(),
        audioCache: cache,
        scrobbleQueue: queue,
      );
      addTearDown(scrobbling.dispose);
      await queue.initialize();
      await queue.queueSubmission('s1', playedAt: DateTime.now());
      await until(() => queue.retryScheduled, 'the retry timer');
      expect(attempts, 1);

      cache.simulateNetworkAvailable();
      await until(() => queue.queueSize == 0, 'the scrobble is sent');

      expect(attempts, 2);
    });
  });

  group('password changed', () {
    // The stream URLs carry the password, like the token and salt do
    var password = 'old';
    String urlWithPassword(String id) => '${urlFor(id)}&p=$password';

    setUp(() {
      password = 'old';
      when(mockApi.getStreamUrl(any)).thenAnswer(
        (invocation) =>
            urlWithPassword(invocation.positionalArguments.first as String),
      );
    });

    test('keeps playing, and loads an item with the old URL again', () async {
      cache.reachable = false;
      await service.playAlbum(albumOf(3));
      await until(
        () => service.playbackState == PlaybackState.playing,
        'playback starts',
      );
      final loads = player.loadedSources.length;

      // The server takes only the new password from now on
      player.failingUrls.addAll([urlWithPassword('s2'), urlWithPassword('s3')]);
      password = 'new';
      service.credentialsChanged();
      expect(service.playbackState, PlaybackState.playing);
      expect(player.loadedSources, hasLength(loads));

      player.simulateTrackTransition();
      await until(
        () => player.loadedSources.last == urlWithPassword('s2'),
        'the queue is loaded again with the new URL',
      );
      await until(
        () => service.playbackState == PlaybackState.playing,
        'playback goes on',
      );
      expect(service.currentIndex, 1);
      expect(player.sequenceSources.last, urlWithPassword('s3'));
    });

    test('downloads the upcoming tracks again with the new password', () async {
      // Refused with the old password until the downloads give up
      cache.failing.addAll(['s2', 's3']);
      await service.playAlbum(albumOf(3));
      await until(() => (cache.attempts['s3'] ?? 0) == 6, 'the retries');
      cache.failing.clear();

      password = 'new';
      service.credentialsChanged();
      await until(() => cache.downloaded.length == 2, 'the downloads');
      expect(cache.downloaded, ['s2', 's3']);
      expect(cache.urls.reversed.take(2), [
        urlWithPassword('s3'),
        urlWithPassword('s2'),
      ]);
    });
  });

  // The play button stays a pause button while a track loads or buffers
  group('pausing while loading', () {
    test('play right after a stop during a slow load plays', () async {
      await service.playAlbum(albumOf(2));
      await service.stop();
      player.loadGate = Completer();

      unawaited(service.play());
      await pumpEventQueue();
      // Stop ends the load; the play right after it comes before the load
      // has noticed
      unawaited(service.stop());
      unawaited(service.play());
      await pumpEventQueue();
      player.loadGate!.complete();
      await pumpEventQueue();

      expect(player.playing, isTrue);
      expect(player.processingState, ProcessingState.ready);
      expect(service.playbackState, PlaybackState.playing);
      expect(service.startsInProgress, 0);
    });

    test('play after a stop and a skip during the slow load plays', () async {
      await service.playAlbum(albumOf(3));
      await Future<void>.delayed(pastSkipDebounce);
      await service.stop();
      player.loadGate = Completer();

      // After the stop the skip loads the queue at its target; Play during
      // that load leaves the start to it
      final skipping = service.next();
      await pumpEventQueue();
      await service.play();
      player.loadGate!.complete();
      await skipping;
      await pumpEventQueue();

      expect(service.currentSong?.id, 's2');
      expect(player.currentIndex, 1);
      expect(player.playing, isTrue);
      expect(service.playbackState, PlaybackState.playing);
      expect(service.startsInProgress, 0);
    });

    test('pause while buffering pauses, play continues', () async {
      cache.reachable = false;
      await service.playAlbum(albumOf(2));
      player.simulateBuffering();
      await until(
        () => service.playbackState == PlaybackState.loading,
        'the service shows the buffering',
      );
      expect(service.playWhenReady, isTrue);

      await service.pause();
      await pumpEventQueue();
      expect(player.playing, isFalse);
      expect(service.playWhenReady, isFalse);

      await service.play();
      await pumpEventQueue();
      expect(player.playing, isTrue);
      expect(service.playWhenReady, isTrue);
    });

    test('pause during a load keeps the track from starting', () async {
      player.loadGate = Completer();
      final loading = service.playAlbum(albumOf(3));
      await until(() => player.loadedSources.isNotEmpty, 'the load starts');
      expect(service.playWhenReady, isTrue);

      await service.pause();
      expect(service.playWhenReady, isFalse);
      player.loadGate!.complete();
      player.loadGate = null;
      await loading;
      await pumpEventQueue();

      expect(player.playing, isFalse);
      expect(service.playbackState, PlaybackState.paused);
      // Nothing that belongs to a started track, like downloading ahead
      expect(cache.downloaded, isEmpty);

      await service.play();
      await until(
        () => service.playbackState == PlaybackState.playing,
        'playback starts',
      );
      await until(() => cache.downloaded.isNotEmpty, 'downloads start');
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test(
      'play after pause during a load starts the track once loaded',
      () async {
        cache.reachable = false;
        player.loadGate = Completer();
        final loading = service.playAlbum(albumOf(2));
        await until(() => player.loadedSources.isNotEmpty, 'the load starts');

        await service.pause();
        await service.play();
        expect(service.playWhenReady, isTrue);
        player.loadGate!.complete();
        player.loadGate = null;
        await loading;

        await until(
          () => service.playbackState == PlaybackState.playing,
          'playback starts',
        );
        expect(player.loadedSources, [urlFor('s1')]);
      },
    );

    test('pause during a skip stays paused on the new track', () async {
      cache.reachable = false;
      await service.playAlbum(albumOf(3));
      await Future<void>.delayed(pastSkipDebounce);
      player.seekGate = Completer();

      final skipping = service.next();
      await until(() => service.currentIndex == 1, 'the skip starts');
      await service.pause();
      player.seekGate!.complete();
      player.seekGate = null;
      await skipping;
      await pumpEventQueue();

      expect(player.currentIndex, 1);
      expect(player.playing, isFalse);
      expect(service.playbackState, PlaybackState.paused);
    });

    test('a load error while paused stays on the track', () async {
      cache.cached.add('s3');
      cache.reachable = false;
      await service.playAlbum(albumOf(3));
      player.simulateBuffering();
      await service.pause();

      player.simulateLoadError();
      await until(
        () => service.playbackState == PlaybackState.stopped,
        'playback stops',
      );
      await pumpEventQueue();

      expect(service.currentIndex, 0);
      expect(player.loadedSources, [urlFor('s1')]);
      expect(player.playing, isFalse);
    });
  });

  group('manual skips', () {
    test('next moves within the queue', () async {
      await service.playAlbum(albumOf(3));
      await Future<void>.delayed(pastSkipDebounce);

      await service.next();

      expect(service.currentIndex, 1);
      expect(player.currentIndex, 1);
      expect(player.loadedSources, [urlFor('s1'), urlFor('s2')]);
      expect(player.sequenceSources.length, 3);
    });

    test('the player moves on normally after previous', () async {
      await service.playAlbum(albumOf(3));
      await Future<void>.delayed(pastSkipDebounce);
      await service.next();
      await Future<void>.delayed(pastSkipDebounce);
      await service.previous();
      expect(service.currentIndex, 0);

      player.simulateTrackTransition();
      await until(() => service.currentIndex == 1, 'the service follows');
    });
  });

  // Commands from the notification, lock screen, Bluetooth and media buttons
  group('system controls', () {
    test('play and pause go through the service', () async {
      await service.playAlbum(albumOf(2));

      player.simulateSystemCommand(SystemCommandType.pause);
      await until(
        () => service.playbackState == PlaybackState.paused,
        'playback pauses',
      );

      player.simulateSystemCommand(SystemCommandType.play);
      await until(
        () => service.playbackState == PlaybackState.playing,
        'playback resumes',
      );
    });

    test('next skips within the queue', () async {
      await service.playAlbum(albumOf(3));
      await Future<void>.delayed(pastSkipDebounce);

      player.simulateSystemCommand(SystemCommandType.next);
      await until(() => service.currentIndex == 1, 'the service skips');

      expect(player.currentIndex, 1);
      expect(player.loadedSources.first, urlFor('s1'));
    });

    test('seek moves the playhead', () async {
      await service.playAlbum(albumOf(2));

      player.simulateSystemCommand(
        SystemCommandType.seek,
        const Duration(seconds: 42),
      );
      await until(
        () => service.currentPosition == const Duration(seconds: 42),
        'the playhead moves',
      );
    });

    test('play after a load error loads the track again', () async {
      cache.reachable = false;
      await service.playAlbum(albumOf(2));
      player.failingUrls.add(urlFor('s2'));
      player.simulateTrackTransition();
      await until(
        () => service.playbackState == PlaybackState.stopped,
        'playback stops',
      );

      player.failingUrls.clear();
      player.simulateSystemCommand(SystemCommandType.play);
      await until(
        () => service.playbackState == PlaybackState.playing,
        'playback resumes',
      );

      expect(player.loadedSources.last, urlFor('s2'));
    });

    test('stop stops playback', () async {
      await service.playAlbum(albumOf(2));

      player.simulateSystemCommand(SystemCommandType.stop);
      await until(
        () => service.playbackState == PlaybackState.stopped,
        'playback stops',
      );

      expect(player.processingState, ProcessingState.idle);
    });
  });
}
