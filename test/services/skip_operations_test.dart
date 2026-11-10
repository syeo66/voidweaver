import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/network_config.dart';
import 'package:voidweaver/services/network_errors.dart';
import 'package:voidweaver/services/settings_service.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:voidweaver/services/replaygain_reader.dart';
import 'package:voidweaver_player/voidweaver_player.dart';

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
  // Whether the fake server delivers audio; off, preloads of upcoming
  // tracks fail as if the network were down
  late AudioPlayerService service;

  String urlFor(String id) => 'https://music.test/rest/stream?id=$id';

  // ReplayGain values are set so the service doesn't try to read them from
  // the (fake) stream URL.
  Song song(String id) => Song(
    id: id,
    title: 'Title $id',
    artist: 'Artist',
    album: 'Album',
    duration: 180,
    replayGainTrackGain: -6.0,
  );

  Album album(int count) => Album(
    id: 'album1',
    name: 'Album',
    artist: 'Artist',
    songs: [for (var i = 1; i <= count; i++) song('s$i')],
  );

  /// An album of [count] songs the server sends no ReplayGain for, so a load
  /// reads its start track's tags (mockApi.readReplayGain) before it hands
  /// the sequence to the player
  Album unreadAlbum(String id, int count) => Album(
    id: id,
    name: 'Album $id',
    artist: 'Artist',
    songs: [
      for (var i = 1; i <= count; i++)
        Song(
          id: '$id-$i',
          title: 'Title $id-$i',
          artist: 'Artist',
          album: 'Album $id',
          duration: 180,
        ),
    ],
  );

  /// Lets the service react to player events emitted on broadcast streams.
  Future<void> settle() => Future.delayed(const Duration(milliseconds: 20));

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});

    mockApi = newMockApi();
    mockSettings = MockSettingsService();
    cache = FakeAudioCache()..reachable = false;
    player = MockAudioPlayer(isCached: cache.isCachedKey);

    when(mockSettings.replayGainMode).thenReturn(ReplayGainMode.off);
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
    ).thenReturn(1.0);

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
    );
  });

  tearDown(() async {
    service.dispose();
    await player.dispose();
  });

  group('starting playback', () {
    test('passes on the error of a failed load unchanged', () async {
      when(
        mockApi.getRandomSongs(any),
      ).thenThrow(const NetworkConnectionException('offline', attemptsMade: 3));

      await expectLater(
        service.playRandomSongs(),
        throwsA(isA<NetworkConnectionException>()),
      );
      expect(service.playbackState, PlaybackState.stopped);
    });

    test(
      'reports an album without songs with a message for the user',
      () async {
        when(mockApi.getAlbum('album1')).thenAnswer((_) async => album(0));

        await expectLater(
          service.playAlbum(album(0)),
          throwsA(
            isA<UserFacingException>().having(
              (e) => e.message,
              'message',
              'Album has no songs',
            ),
          ),
        );
      },
    );
  });

  group('next()', () {
    test('loads and plays the following track', () async {
      await service.playAlbum(album(3));
      await Future<void>.delayed(pastSkipDebounce);

      await service.next();

      expect(service.currentIndex, 1);
      expect(service.currentSong?.id, 's2');
      expect(player.loadedSources, [urlFor('s1'), urlFor('s2')]);
      expect(service.isSkipOperationInProgress, isFalse);
    });

    test('does nothing on the last track', () async {
      await service.playAlbum(album(1));

      await service.next();

      expect(service.currentIndex, 0);
      expect(service.hasNext, isFalse);
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('ignores a second skip within the debounce window', () async {
      await service.playAlbum(album(3));
      await Future<void>.delayed(pastSkipDebounce);

      await service.next();
      await service.next();

      expect(service.currentIndex, 1);
    });

    test('presses during a slow skip move on from its target', () async {
      await service.playAlbum(album(4));
      player.seekGate = Completer();

      final skipping = service.next();
      await Future<void>.delayed(pastSkipDebounce);
      unawaited(service.next());
      await Future<void>.delayed(pastSkipDebounce);
      unawaited(service.next());
      expect(service.currentIndex, 1);
      expect(service.isSkipOperationInProgress, isTrue);

      player.seekGate!.complete();
      await skipping;

      expect(service.currentIndex, 3);
      expect(player.currentIndex, 3);
      expect(service.isSkipOperationInProgress, isFalse);
    });

    test(
      'a pause during a slow skip holds when presses moved its target',
      () async {
        await service.playAlbum(album(4));
        player.seekGate = Completer();

        final skipping = service.next();
        await Future<void>.delayed(pastSkipDebounce);
        unawaited(service.next());
        await service.pause();
        player.seekGate!.complete();
        await skipping;
        await pumpEventQueue();

        expect(service.currentIndex, 2);
        expect(player.currentIndex, 2);
        expect(player.playing, isFalse);
        expect(service.playbackState, PlaybackState.paused);
      },
    );

    test('a play after a pause during a slow skip plays its target', () async {
      await service.playAlbum(album(4));
      player.seekGate = Completer();

      final skipping = service.next();
      await Future<void>.delayed(pastSkipDebounce);
      unawaited(service.next());
      await service.pause();
      await service.play();
      player.seekGate!.complete();
      await skipping;
      await pumpEventQueue();

      expect(player.currentIndex, 2);
      expect(player.playing, isTrue);
    });

    test(
      'a stop during a slow skip holds when presses moved its target',
      () async {
        await service.playAlbum(album(4));
        player.seekGate = Completer();

        final skipping = service.next();
        await Future<void>.delayed(pastSkipDebounce);
        unawaited(service.next());
        await service.stop();
        player.seekGate!.complete();
        await skipping;
        await pumpEventQueue();

        expect(service.currentIndex, 2);
        expect(player.playing, isFalse);
      },
    );

    test('presses during a skip stop at the last track', () async {
      await service.playAlbum(album(3));
      player.seekGate = Completer();

      final skipping = service.next();
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(pastSkipDebounce);
        unawaited(service.next());
      }
      player.seekGate!.complete();
      await skipping;

      expect(service.currentIndex, 2);
      expect(player.currentIndex, 2);
    });

    test(
      'a skip while a new album is still being prepared moves within it',
      () async {
        await service.playAlbum(album(3));
        await Future<void>.delayed(pastSkipDebounce);
        // The new album's songs have no ReplayGain from the server, so its
        // load reads the start track's tags before handing the sequence to
        // the player; until then the player still holds the old album
        final gainRead = Completer<ReplayGainData>();
        when(mockApi.readReplayGain(any)).thenAnswer((_) => gainRead.future);
        final newAlbum = Album(
          id: 'album2',
          name: 'New',
          artist: 'Artist',
          songs: [
            for (var i = 1; i <= 3; i++)
              Song(
                id: 'n$i',
                title: 'New $i',
                artist: 'Artist',
                album: 'New',
                duration: 180,
              ),
          ],
        );

        final starting = service.playAlbum(newAlbum);
        await pumpEventQueue();
        final skipping = service.next();
        await pumpEventQueue();
        gainRead.complete(const ReplayGainData());
        await starting;
        await skipping;
        await settle();

        expect(player.sequenceSources, [
          for (var i = 1; i <= 3; i++) urlFor('n$i'),
        ]);
        expect(service.currentSong?.id, 'n2');
        expect(service.currentIndex, 1);
        expect(player.currentIndex, 1);
        expect(player.playing, isTrue);
        // Never the old album's second track
        expect(player.loadedSources, isNot(contains(urlFor('s2'))));
      },
    );

    test(
      'a skip pressed while the track loads takes over when the load fails',
      () async {
        final errors = <String>[];
        service.playbackErrors.listen(errors.add);
        await service.playAlbum(album(3));
        await service.stop();
        // Play loads the queue again; s1 takes a while, then fails
        player.loadGate = Completer();
        player.failingUrls.add(urlFor('s1'));

        unawaited(service.play());
        await pumpEventQueue();
        final skipping = service.next();
        await pumpEventQueue();
        player.loadGate!.complete();
        await skipping;
        await settle();

        // s1's failure isn't reported: the skip had already moved on
        expect(errors, isEmpty);
        expect(service.currentSong?.id, 's2');
        expect(player.currentIndex, 1);
        expect(player.loadedSources.last, urlFor('s2'));
        expect(player.processingState, ProcessingState.ready);
        expect(player.playing, isTrue);
        expect(service.playbackState, PlaybackState.playing);
      },
    );

    test(
      'a skip queued behind a starting album leaves the start to the skip',
      () async {
        await service.playAlbum(album(3));
        await service.stop();
        player.loadGate = Completer();
        // The skip's target can't be played
        player.failingUrls.add(urlFor('s2'));

        unawaited(service.play());
        await pumpEventQueue();
        // Queued behind the load, which then finishes
        final skipping = service.next();
        player.loadGate!.complete();
        await skipping;
        await settle();
        // The scrobble queue sends requests asynchronously, 100 ms apart
        await Future<void>.delayed(const Duration(milliseconds: 500));

        // The load didn't announce the skip's target as playing
        verifyNever(mockApi.scrobbleNowPlaying('s2'));
        expect(service.currentSong?.id, 's2');
        expect(service.playbackState, PlaybackState.stopped);
        expect(service.startsInProgress, 0);
      },
    );

    test(
      'Previous while a new album is still being prepared starts it',
      () async {
        await service.playAlbum(album(3));
        await Future<void>.delayed(pastSkipDebounce);
        final gainRead = Completer<ReplayGainData>();
        when(mockApi.readReplayGain(any)).thenAnswer((_) => gainRead.future);

        final starting = service.playAlbum(unreadAlbum('n', 3));
        await pumpEventQueue();
        // Its target is the start track the load is preparing
        final skipping = service.previous();
        await pumpEventQueue();
        gainRead.complete(const ReplayGainData());
        await starting;
        await skipping;
        await settle();

        expect(player.sequenceSources, [
          for (var i = 1; i <= 3; i++) urlFor('n-$i'),
        ]);
        expect(service.currentSong?.id, 'n-1');
        expect(player.currentIndex, 0);
        expect(player.playing, isTrue);
        // Nothing seeked within the old album
        expect(player.seeks, isEmpty);
        expect(service.startsInProgress, 0);
      },
    );

    test(
      'a pause after a skip while a new album is being prepared holds',
      () async {
        await service.playAlbum(album(3));
        await Future<void>.delayed(pastSkipDebounce);
        final gainRead = Completer<ReplayGainData>();
        when(mockApi.readReplayGain(any)).thenAnswer((_) => gainRead.future);

        final starting = service.playAlbum(unreadAlbum('n', 3));
        await pumpEventQueue();
        final skipping = service.next();
        await pumpEventQueue();
        await service.pause();
        gainRead.complete(const ReplayGainData());
        await starting;
        await skipping;
        await settle();

        expect(service.currentSong?.id, 'n-2');
        expect(player.currentIndex, 1);
        expect(player.playing, isFalse);
        expect(service.playbackState, PlaybackState.paused);
        expect(service.startsInProgress, 0);
      },
    );

    test(
      'an album started while a skip waits behind the last one plays',
      () async {
        await service.playAlbum(album(3));
        await service.stop();
        player.loadGate = Completer();

        unawaited(service.play());
        await pumpEventQueue();
        // Queued behind the load; then another album replaces the queue
        // before the skip gets to move
        final skipping = service.next();
        final starting = service.playAlbum(unreadAlbum('n', 2));
        await pumpEventQueue();
        player.loadGate!.complete();
        await skipping;
        await starting;
        await settle();

        expect(player.sequenceSources, [urlFor('n-1'), urlFor('n-2')]);
        expect(service.currentSong?.id, 'n-1');
        expect(player.playing, isTrue);
        expect(service.playbackState, PlaybackState.playing);
        expect(service.startsInProgress, 0);
      },
    );

    test('a skip target that fails after a pause during the skip stops on it, '
        'reported once', () async {
      final errors = <String>[];
      service.playbackErrors.listen(errors.add);
      await service.playAlbum(album(3));
      await Future<void>.delayed(pastSkipDebounce);
      player.seekGate = Completer();
      player.failingUrls.add(urlFor('s2'));

      final skipping = service.next();
      await pumpEventQueue();
      await service.pause();
      player.seekGate!.complete();
      await skipping;
      await settle();

      expect(errors, [startsWith('Could not play "Title s2"')]);
      expect(service.currentSong?.id, 's2');
      expect(service.playbackState, PlaybackState.stopped);
      expect(player.playing, isFalse);
      expect(service.startsInProgress, 0);
    });

    test('a press during a skip moves on past a target that fails, unreported, '
        'also when paused', () async {
      final errors = <String>[];
      service.playbackErrors.listen(errors.add);
      await service.playAlbum(album(3));
      await Future<void>.delayed(pastSkipDebounce);
      player.seekGate = Completer();
      player.failingUrls.add(urlFor('s2'));

      final skipping = service.next();
      await Future<void>.delayed(pastSkipDebounce);
      unawaited(service.next());
      // Paused, s2's failure would otherwise stop playback on it at once
      await service.pause();
      player.seekGate!.complete();
      await skipping;
      await settle();

      expect(errors, isEmpty);
      expect(service.currentSong?.id, 's3');
      expect(player.currentIndex, 2);
      expect(player.playing, isFalse);
      expect(service.playbackState, PlaybackState.paused);
      expect(service.startsInProgress, 0);
    });

    test('a track failing while a skip reads its target\'s tags doesn\'t end '
        'the skip', () async {
      final errors = <String>[];
      service.playbackErrors.listen(errors.add);
      final songs = unreadAlbum('u', 3);
      await service.playAlbum(songs);
      await Future<void>.delayed(pastSkipDebounce);
      final gainRead = Completer<ReplayGainData>();
      when(mockApi.readReplayGain('u-2')).thenAnswer((_) => gainRead.future);

      final skipping = service.next();
      await pumpEventQueue();
      // The track that's playing breaks off before the skip seeks
      player.simulateLoadError();
      await pumpEventQueue();
      gainRead.complete(const ReplayGainData());
      await skipping;
      await settle();

      expect(errors, isEmpty);
      expect(service.currentSong?.id, 'u-2');
      expect(player.currentIndex, 1);
      expect(player.processingState, ProcessingState.ready);
      expect(player.playing, isTrue);
      expect(service.playbackState, PlaybackState.playing);
    });

    test('the error of the track a skip left, arriving during its seek, '
        'leaves the skip to load its target', () async {
      final errors = <String>[];
      service.playbackErrors.listen(errors.add);
      await service.playAlbum(album(3));
      await Future<void>.delayed(pastSkipDebounce);
      player.seekGate = Completer();

      final skipping = service.next();
      await pumpEventQueue();
      // The track being left stalled and fails at the end of its retries;
      // its error comes while the seek waits
      player.simulateLoadError(index: 0);
      player.seekGate!.complete();
      player.seekGate = null;
      await skipping;
      await settle();

      expect(errors, isEmpty);
      expect(service.currentIndex, 1);
      expect(player.currentIndex, 1);
      expect(player.processingState, ProcessingState.ready);
      expect(player.playing, isTrue);
      expect(service.playbackState, PlaybackState.playing);
    });

    test('a stop while a skip back reads its target\'s tags isn\'t taken for '
        'the target ending', () async {
      await service.playAlbum(unreadAlbum('u', 3));
      await Future<void>.delayed(pastSkipDebounce);
      await service.next();
      await settle();
      await Future<void>.delayed(pastSkipDebounce);
      final gainRead = Completer<ReplayGainData>();
      when(mockApi.readReplayGain('u-1')).thenAnswer((_) => gainRead.future);
      clearInteractions(mockApi);

      final skipping = service.previous();
      await pumpEventQueue();
      await service.stop();
      gainRead.complete(const ReplayGainData());
      await skipping;
      await settle();
      // The scrobble queue sends requests asynchronously, 100 ms apart
      await Future<void>.delayed(const Duration(milliseconds: 500));

      verifyNever(
        mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')),
      );
      // The stop holds: the skip reaches its target, paused
      expect(service.currentSong?.id, 'u-1');
      expect(player.currentIndex, 0);
      expect(player.playing, isFalse);
    });

    test('a skip queued behind a load that fails takes over before the failure '
        'is reported, also when its target reads its tags first', () async {
      final errors = <String>[];
      service.playbackErrors.listen(errors.add);
      await service.playAlbum(unreadAlbum('u', 3));
      await service.stop();
      player.loadGate = Completer();
      player.failingUrls.add(urlFor('u-1'));
      final gainRead = Completer<ReplayGainData>();
      when(mockApi.readReplayGain('u-2')).thenAnswer((_) => gainRead.future);

      unawaited(service.play());
      await pumpEventQueue();
      final skipping = service.next();
      await pumpEventQueue();
      // u-1 fails while the skip waits behind its load; the skip would
      // then make u-2 current and read its tags before seeking
      player.loadGate!.complete();
      await pumpEventQueue();
      gainRead.complete(const ReplayGainData());
      await skipping;
      await settle();

      // Neither "Could not play u-2" (misnamed) nor u-1 (superseded)
      expect(errors, isEmpty);
      expect(service.currentSong?.id, 'u-2');
      expect(player.currentIndex, 1);
      expect(player.playing, isTrue);
      expect(service.playbackState, PlaybackState.playing);
    });

    test('allows another skip once the debounce window has passed', () async {
      await service.playAlbum(album(3));
      await Future<void>.delayed(pastSkipDebounce);

      await service.next();
      await Future<void>.delayed(pastSkipDebounce);
      await service.next();

      expect(service.currentIndex, 2);
      expect(service.currentSong?.id, 's3');
    });

    test('skips past an unreachable track to the next cached one', () async {
      cache.cached.add('s3');

      await service.playAlbum(album(3));
      await Future<void>.delayed(pastSkipDebounce);
      player.failingUrls.add(urlFor('s2'));

      await service.next();
      // The player reports the load error during the seek
      await settle();

      expect(service.currentIndex, 2);
      expect(service.currentSong?.id, 's3');
      expect(player.loadedSources.last, urlFor('s3'));
    });

    test('stops on a track that can\'t load when nothing later can', () async {
      await service.playAlbum(album(2));
      await Future<void>.delayed(pastSkipDebounce);
      player.failingUrls.add(urlFor('s2'));

      await service.next();
      await settle();

      expect(service.isSkipOperationInProgress, isFalse);
      expect(service.currentSong?.id, 's2');
      expect(service.playbackState, PlaybackState.stopped);
    });
  });

  group('previous()', () {
    test('restarts the first track', () async {
      await service.playAlbum(album(3));
      player.simulatePositionChange(const Duration(seconds: 1));
      await settle();

      await service.previous();

      expect(service.currentIndex, 0);
      expect(service.hasPrevious, isFalse);
      expect(player.position, Duration.zero);
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('restarts a track that has played for a few seconds', () async {
      await service.playAlbum(album(3));
      await Future<void>.delayed(pastSkipDebounce);
      await service.next();
      await Future<void>.delayed(pastSkipDebounce);
      player.simulatePositionChange(const Duration(seconds: 10));
      await settle();

      await service.previous();

      expect(service.currentIndex, 1);
      expect(service.currentPosition, Duration.zero);
      expect(player.position, Duration.zero);
      expect(service.playbackState, PlaybackState.playing);
    });

    test('a restart counts as a new play', () async {
      when(mockApi.scrobbleNowPlaying(any)).thenAnswer((_) async {});
      await service.playAlbum(album(3));
      player.simulatePositionChange(const Duration(seconds: 10));
      await settle();

      await service.previous();
      // The scrobble queue sends requests asynchronously, 100 ms apart
      await Future<void>.delayed(const Duration(milliseconds: 500));

      verify(mockApi.scrobbleNowPlaying('s1')).called(2);
    });

    test('goes back from the target when pressed during a skip', () async {
      await service.playAlbum(album(3));
      player.seekGate = Completer();

      final skipping = service.next();
      // A late position update of the track being skipped
      player.simulatePositionChange(const Duration(seconds: 10));
      await settle();
      await Future<void>.delayed(pastSkipDebounce);
      unawaited(service.previous());
      player.seekGate!.complete();
      await skipping;

      expect(service.currentIndex, 0);
      expect(player.currentIndex, 0);
    });

    test('goes back to the preceding track', () async {
      await service.playAlbum(album(3));
      await Future<void>.delayed(pastSkipDebounce);
      await service.next();
      await Future<void>.delayed(pastSkipDebounce);

      await service.previous();

      expect(service.currentIndex, 0);
      expect(service.currentSong?.id, 's1');
      expect(player.loadedSources.last, urlFor('s1'));
    });
  });

  group('song completion', () {
    test('advances to the next track', () async {
      await service.playAlbum(album(3));

      player.simulateCompletion();
      await settle();

      expect(service.currentIndex, 1);
      expect(service.currentSong?.id, 's2');
      expect(service.isSkipOperationInProgress, isFalse);
    });

    test('advances once per index event, however often it repeats', () async {
      await service.playAlbum(album(3));

      player.simulateCompletion();
      player.simulateIndexEvent(1);
      player.simulateIndexEvent(1);
      await settle();

      expect(service.currentIndex, 1);
      // The player moved on by itself; nothing was loaded
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('handles repeated end-of-playlist events once', () async {
      await service.playAlbum(album(1));

      player.simulateCompletion();
      player.simulateCompletion();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      verify(mockApi.scrobbleSubmission('s1', playedAt: anyNamed('playedAt')))
          .called(1);
    });

    test('pauses at the end of the playlist', () async {
      await service.playAlbum(album(1));

      player.simulateCompletion();
      await settle();

      expect(service.currentIndex, 0);
      expect(service.playbackState, PlaybackState.paused);
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('pausing just before the end does not advance', () async {
      await service.playAlbum(album(3));
      player.simulatePositionChange(const Duration(minutes: 2, seconds: 59));
      await settle();

      await service.pause();
      await settle();

      expect(service.currentIndex, 0);
      expect(service.playbackState, PlaybackState.paused);
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('scrobbles the completed track', () async {
      await service.playAlbum(album(2));

      player.simulateCompletion();
      // The scrobble queue sends requests asynchronously
      await Future<void>.delayed(const Duration(milliseconds: 200));

      verify(mockApi.scrobbleSubmission('s1', playedAt: anyNamed('playedAt')))
          .called(1);
    });
  });

  group('seekTo()', () {
    test('during a slow skip seeks in the track it skips to', () async {
      await service.playAlbum(album(3));
      player.seekGate = Completer();

      final skipping = service.next();
      // Under way: the app shows the track it skips to
      await settle();
      expect(service.currentIndex, 1);
      final seeking = service.seekTo(const Duration(seconds: 60));
      player.seekGate!.complete();
      await skipping;
      await seeking;

      expect(player.currentIndex, 1);
      expect(player.position, const Duration(seconds: 60));
    });

    test('before a new queue is loaded moves where it starts', () async {
      final reading = Completer<ReplayGainData>();
      when(mockApi.readReplayGain(any)).thenAnswer((_) => reading.future);
      final unread = Album(
        id: 'album2',
        name: 'Album',
        artist: 'Artist',
        songs: [
          Song(
            id: 'u1',
            title: 'Title u1',
            artist: 'Artist',
            album: 'Album',
            duration: 180,
          ),
        ],
      );

      final starting = service.playAlbum(unread);
      await settle();
      await service.seekTo(const Duration(seconds: 30));
      expect(service.currentPosition, const Duration(seconds: 30));
      reading.complete(const ReplayGainData());
      await starting;

      expect(player.position, const Duration(seconds: 30));
      expect(service.currentPosition, const Duration(seconds: 30));
    });
  });
}
