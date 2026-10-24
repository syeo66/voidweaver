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

import '../test_helpers/fake_audio_cache.dart';
import '../test_helpers/mock_audio_player.dart';
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

  /// Lets the service react to player events emitted on broadcast streams.
  Future<void> settle() => Future.delayed(const Duration(milliseconds: 20));

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});

    mockApi = MockSubsonicApi();
    mockSettings = MockSettingsService();
    cache = FakeAudioCache()..reachable = false;
    player = MockAudioPlayer(isCached: cache.isCachedKey);

    when(mockSettings.replayGainMode).thenReturn(ReplayGainMode.off);
    when(mockSettings.replayGainPreamp).thenReturn(0.0);
    when(mockSettings.replayGainFallbackGain).thenReturn(0.0);
    when(mockSettings.replayGainPreventClipping).thenReturn(true);
    when(mockSettings.scrobbleMinPlayTimeMinutes).thenReturn(4.0);
    when(mockSettings.scrobbleThresholdPercent).thenReturn(50.0);
    when(mockSettings.calculateVolumeAdjustment(
      trackGain: anyNamed('trackGain'),
      albumGain: anyNamed('albumGain'),
      trackPeak: anyNamed('trackPeak'),
      albumPeak: anyNamed('albumPeak'),
    )).thenReturn(1.0);

    when(mockApi.getStreamUrl(any)).thenAnswer(
        (invocation) => urlFor(invocation.positionalArguments.first as String));
    when(mockApi.readReplayGain(any))
        .thenAnswer((_) async => const ReplayGainData());

    service = AudioPlayerService(mockApi, mockSettings,
        audioPlayer: player, audioCache: cache);
  });

  tearDown(() async {
    service.dispose();
    await player.dispose();
  });

  group('starting playback', () {
    test('passes on the error of a failed load unchanged', () async {
      when(mockApi.getRandomSongs(any)).thenThrow(
          const NetworkConnectionException('offline', attemptsMade: 3));

      await expectLater(service.playRandomSongs(),
          throwsA(isA<NetworkConnectionException>()));
      expect(service.playbackState, PlaybackState.stopped);
    });

    test('reports an album without songs with a message for the user',
        () async {
      when(mockApi.getAlbum('album1')).thenAnswer((_) async => album(0));

      await expectLater(
          service.playAlbum(album(0)),
          throwsA(isA<UserFacingException>()
              .having((e) => e.message, 'message', 'Album has no songs')));
    });
  });

  group('next()', () {
    test('loads and plays the following track', () async {
      await service.playAlbum(album(3));
      await Future.delayed(pastSkipDebounce);

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
      await Future.delayed(pastSkipDebounce);

      await service.next();
      await service.next();

      expect(service.currentIndex, 1);
    });

    test('presses during a slow skip move on from its target', () async {
      await service.playAlbum(album(4));
      player.seekGate = Completer();

      final skipping = service.next();
      await Future.delayed(pastSkipDebounce);
      unawaited(service.next());
      await Future.delayed(pastSkipDebounce);
      unawaited(service.next());
      expect(service.currentIndex, 1);
      expect(service.isSkipOperationInProgress, isTrue);

      player.seekGate!.complete();
      await skipping;

      expect(service.currentIndex, 3);
      expect(player.currentIndex, 3);
      expect(service.isSkipOperationInProgress, isFalse);
    });

    test('presses during a skip stop at the last track', () async {
      await service.playAlbum(album(3));
      player.seekGate = Completer();

      final skipping = service.next();
      for (var i = 0; i < 3; i++) {
        await Future.delayed(pastSkipDebounce);
        unawaited(service.next());
      }
      player.seekGate!.complete();
      await skipping;

      expect(service.currentIndex, 2);
      expect(player.currentIndex, 2);
    });

    test('allows another skip once the debounce window has passed', () async {
      await service.playAlbum(album(3));
      await Future.delayed(pastSkipDebounce);

      await service.next();
      await Future.delayed(pastSkipDebounce);
      await service.next();

      expect(service.currentIndex, 2);
      expect(service.currentSong?.id, 's3');
    });

    test('skips past an unreachable track to the next cached one', () async {
      cache.cached.add('s3');

      await service.playAlbum(album(3));
      await Future.delayed(pastSkipDebounce);
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
      await Future.delayed(pastSkipDebounce);
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
      await Future.delayed(pastSkipDebounce);
      await service.next();
      await Future.delayed(pastSkipDebounce);
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
      await Future.delayed(const Duration(milliseconds: 500));

      verify(mockApi.scrobbleNowPlaying('s1')).called(2);
    });

    test('goes back from the target when pressed during a skip', () async {
      await service.playAlbum(album(3));
      player.seekGate = Completer();

      final skipping = service.next();
      // A late position update of the track being skipped
      player.simulatePositionChange(const Duration(seconds: 10));
      await settle();
      await Future.delayed(pastSkipDebounce);
      unawaited(service.previous());
      player.seekGate!.complete();
      await skipping;

      expect(service.currentIndex, 0);
      expect(player.currentIndex, 0);
    });

    test('goes back to the preceding track', () async {
      await service.playAlbum(album(3));
      await Future.delayed(pastSkipDebounce);
      await service.next();
      await Future.delayed(pastSkipDebounce);

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
      await Future.delayed(const Duration(milliseconds: 200));

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
      await Future.delayed(const Duration(milliseconds: 200));

      verify(mockApi.scrobbleSubmission('s1', playedAt: anyNamed('playedAt')))
          .called(1);
    });
  });
}
