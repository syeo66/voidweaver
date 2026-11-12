import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/scrobble_queue.dart';
import 'package:voidweaver/services/settings_service.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:voidweaver/services/replaygain_reader.dart';

import '../test_helpers/fake_audio_cache.dart';
import '../test_helpers/mock_audio_player.dart';
import '../test_helpers/mock_api.dart';
import '../test_helpers/mocks.mocks.dart';

/// A track that stops because the network failed while it streamed is played
/// again, where it broke off, once the network is back (see
/// docs/PLAYBACK.md, "Load errors").
void main() {
  // Media3's PlaybackException codes
  const networkFailed = 2001; // ERROR_CODE_IO_NETWORK_CONNECTION_FAILED
  const networkTimeout = 2002; // ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT
  const errorDocument = 2000; // ERROR_CODE_IO_UNSPECIFIED, see LoadErrorPolicy
  const badHttpStatus = 2004; // ERROR_CODE_IO_BAD_HTTP_STATUS
  // AudioPlayerService.networkResumeWindow
  const resumeWindow = Duration(minutes: 10);

  late MockSubsonicApi mockApi;
  late MockSettingsService mockSettings;
  late MockAudioPlayer player;
  late FakeAudioCache cache;
  late AudioPlayerService service;

  String urlFor(String id) => 'https://music.test/rest/stream?id=$id';

  Song song(String id) => Song(
    id: id,
    title: 'Title $id',
    artist: 'Artist',
    album: 'Album',
    duration: 240,
    replayGainTrackGain: -6.0,
  );

  Album album(int count) => Album(
    id: 'album1',
    name: 'Album',
    artist: 'Artist',
    songs: [for (var i = 1; i <= count; i++) song('s$i')],
  );

  Future<void> settle() => pumpEventQueue();

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = newMockApi();
    mockSettings = MockSettingsService();
    // Downloads of upcoming tracks fail, as with the network down
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
      scrobbleQueue: ScrobbleQueue(mockApi),
      clock: player.clock,
    );
  });

  tearDown(() async {
    service.dispose();
    await player.dispose();
  });

  /// Plays an album of [count] songs to [position] in its first track, where
  /// the stream then fails with [code], with nothing downloaded to go on at.
  Future<void> failWhileStreaming(
    int code, {
    int count = 3,
    Duration position = const Duration(seconds: 90),
  }) async {
    await service.playAlbum(album(count));
    player.simulatePlayingTo(position);
    await settle();
    player.simulateLoadError(code: code);
    await settle();
  }

  group('a track the network fails on, with nothing downloaded after it', () {
    test('stops where it broke off, reported', () async {
      final errors = <String>[];
      service.playbackErrors.listen(errors.add);

      await failWhileStreaming(networkFailed);

      expect(service.currentSong?.id, 's1');
      expect(service.playbackState, PlaybackState.stopped);
      expect(service.currentPosition, const Duration(seconds: 90));
      expect(errors, hasLength(1));
    });

    test('plays on where it broke off once the network is back', () async {
      await failWhileStreaming(networkFailed);
      final loads = player.loadedSources.length;

      cache.simulateNetworkAvailable();
      await settle();

      expect(player.loadedSources.length, loads + 1);
      expect(player.loadedSources.last, urlFor('s1'));
      expect(player.position, const Duration(seconds: 90));
      expect(player.playing, isTrue);
      expect(service.playbackState, PlaybackState.playing);
      expect(service.currentSong?.id, 's1');
    });

    test('also ${resumeWindow.inMinutes} minutes later', () async {
      await failWhileStreaming(networkFailed);
      player.now = player.now.add(resumeWindow);

      cache.simulateNetworkAvailable();
      await settle();

      expect(service.playbackState, PlaybackState.playing);
    });

    test('also after a timeout', () async {
      await failWhileStreaming(networkTimeout);

      cache.simulateNetworkAvailable();
      await settle();

      expect(player.position, const Duration(seconds: 90));
      expect(service.playbackState, PlaybackState.playing);
    });

    test('resumes once: a second network event does nothing', () async {
      await failWhileStreaming(networkFailed);
      cache.simulateNetworkAvailable();
      await settle();
      final loads = player.loadedSources.length;

      cache.simulateNetworkAvailable();
      await settle();

      expect(player.loadedSources.length, loads);
    });

    test('is armed again when the resume fails for the network too', () async {
      await failWhileStreaming(networkFailed);
      player.failingUrls.add(urlFor('s1'));
      player.errorCode = networkFailed;

      cache.simulateNetworkAvailable();
      await settle();
      expect(service.playbackState, PlaybackState.stopped);
      expect(service.currentPosition, const Duration(seconds: 90));

      player.failingUrls.clear();
      cache.simulateNetworkAvailable();
      await settle();

      expect(player.position, const Duration(seconds: 90));
      expect(service.playbackState, PlaybackState.playing);
    });

    test('play() goes on where it broke off', () async {
      await failWhileStreaming(networkFailed);

      await service.play();
      await settle();

      expect(player.loadedSources.last, urlFor('s1'));
      expect(player.position, const Duration(seconds: 90));
      expect(service.playbackState, PlaybackState.playing);
    });

    test('a seek while stopped moves where it resumes', () async {
      await failWhileStreaming(networkFailed);
      await service.seekTo(const Duration(seconds: 30));

      cache.simulateNetworkAvailable();
      await settle();

      expect(player.loadedSources.last, urlFor('s1'));
      expect(player.position, const Duration(seconds: 30));
      expect(service.playbackState, PlaybackState.playing);
    });

    test('a skip the network fails as well resumes the skip\'s target from '
        'its start', () async {
      await failWhileStreaming(networkFailed);
      player.failingUrls.add(urlFor('s2'));
      player.errorCode = networkFailed;
      player.now = player.now.add(const Duration(seconds: 1));
      await service.next();
      await settle();
      expect(service.currentSong?.id, 's2');
      expect(service.playbackState, PlaybackState.stopped);

      player.failingUrls.clear();
      cache.simulateNetworkAvailable();
      await settle();

      expect(player.loadedSources.last, urlFor('s2'));
      expect(player.position, Duration.zero);
      expect(service.currentSong?.id, 's2');
      expect(service.playbackState, PlaybackState.playing);
    });

    test('the next track failing as the player moves there resumes it from '
        'its start', () async {
      // The current track ran out, and the player moved on to the next one,
      // which it couldn't load; the error reaches the service before the
      // index event
      await service.playAlbum(album(3));
      player.simulatePlayingTo(const Duration(minutes: 3, seconds: 59));
      await settle();
      expect(service.currentIndex, 0);

      player.simulateLoadError(index: 1, code: networkFailed);
      await settle();
      expect(service.currentSong?.id, 's2');
      expect(service.playbackState, PlaybackState.stopped);
      expect(service.currentPosition, Duration.zero);

      cache.simulateNetworkAvailable();
      await settle();

      expect(player.loadedSources.last, urlFor('s2'));
      expect(player.position, Duration.zero);
      expect(service.currentSong?.id, 's2');
      expect(service.playbackState, PlaybackState.playing);
    });
  });

  group('the network coming back does nothing', () {
    Future<void> expectNoResume() async {
      final loads = player.loadedSources.length;
      final state = service.playbackState;
      cache.simulateNetworkAvailable();
      await settle();
      expect(player.loadedSources.length, loads);
      expect(service.playbackState, state);
    }

    test('after the server answered with a document instead of audio, and '
        'play() starts that track over', () async {
      await failWhileStreaming(errorDocument);
      await expectNoResume();
      expect(service.playbackState, PlaybackState.stopped);

      await service.play();
      await settle();
      expect(player.position, Duration.zero);
    });

    test('after an HTTP error', () async {
      await failWhileStreaming(badHttpStatus);
      await expectNoResume();
    });

    test('after an error of no particular cause', () async {
      await failWhileStreaming(0);
      await expectNoResume();
    });

    test('after a pause', () async {
      await failWhileStreaming(networkFailed);
      await service.pause();
      await expectNoResume();
    });

    test('after a stop', () async {
      await failWhileStreaming(networkFailed);
      await service.stop();
      await settle();
      await expectNoResume();
    });

    test('after a skip that failed for another cause', () async {
      await failWhileStreaming(networkFailed);
      player.failingUrls.add(urlFor('s2'));
      player.now = player.now.add(const Duration(seconds: 1));
      await service.next();
      await settle();
      expect(service.currentSong?.id, 's2');
      expect(service.playbackState, PlaybackState.stopped);

      player.failingUrls.clear();
      await expectNoResume();
    });

    test(
      'after a Play on the same track that failed for another cause',
      () async {
        await failWhileStreaming(networkFailed);
        player.failingUrls.add(urlFor('s1'));

        await service.play();
        await settle();
        expect(service.currentSong?.id, 's1');
        expect(service.playbackState, PlaybackState.stopped);

        player.failingUrls.clear();
        await expectNoResume();
      },
    );

    test('after another queue was started', () async {
      await failWhileStreaming(networkFailed);
      await service.playAlbum(
        Album(
          id: 'album2',
          name: 'Other',
          artist: 'Artist',
          songs: [song('x')],
        ),
      );
      await settle();
      expect(service.playbackState, PlaybackState.playing);
      await expectNoResume();
    });

    test(
      'more than ${resumeWindow.inMinutes} minutes after the failure',
      () async {
        await failWhileStreaming(networkFailed);
        player.now = player.now.add(resumeWindow + const Duration(seconds: 1));
        await expectNoResume();
      },
    );

    test('when it was paused as it failed', () async {
      await service.playAlbum(album(3));
      player.simulatePlayingTo(const Duration(seconds: 90));
      await service.pause();
      await settle();
      player.simulateLoadError(code: networkFailed);
      await settle();
      await expectNoResume();
    });

    test('when it went on at a downloaded track', () async {
      cache.cached.add('s2');
      await failWhileStreaming(networkFailed);
      expect(service.currentSong?.id, 's2');
      expect(service.playbackState, PlaybackState.playing);

      await expectNoResume();
    });

    test('after the service was disposed', () async {
      await failWhileStreaming(networkFailed);
      final loads = player.loadedSources.length;
      service.dispose();
      cache.simulateNetworkAvailable();
      await settle();
      expect(player.loadedSources.length, loads);
      // tearDown disposes it again
      service = AudioPlayerService(
        mockApi,
        mockSettings,
        audioPlayer: MockAudioPlayer(),
        audioCache: FakeAudioCache(),
        scrobbleQueue: ScrobbleQueue(mockApi),
      );
    });
  });
}
