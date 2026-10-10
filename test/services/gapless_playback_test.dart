import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/audio_cache.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/settings_service.dart';
import 'package:voidweaver/services/subsonic_api.dart';

import '../test_helpers/mock_audio_player.dart';
import 'gapless_playback_test.mocks.dart';

@GenerateMocks([SubsonicApi, SettingsService])
void main() {
  // Skips within this window of the previous one are ignored by the service
  const pastSkipDebounce = Duration(milliseconds: 250);

  late Directory cacheDir;
  late MockSubsonicApi mockApi;
  late MockSettingsService mockSettings;
  late MockAudioPlayer player;
  late AudioCache cache;
  late AudioPlayerService service;
  late bool serverReachable;
  // When set, downloads wait for it to complete
  Completer<void>? downloadGate;

  String urlFor(String id) => 'https://music.test/rest/stream?id=$id';
  String fileFor(String id) => 'file:${cache.getCachedFile(id)?.path}';

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

  /// Waits until [condition] holds, failing after a second.
  Future<void> until(bool Function() condition, String description) async {
    for (var i = 0; i < 100; i++) {
      if (condition()) return;
      await Future.delayed(const Duration(milliseconds: 10));
    }
    fail('Timed out waiting until $description');
  }

  /// Whether the player's item at [index] is the downloaded file of [id].
  bool playsFromCache(int index, String id) =>
      index < player.sequenceSources.length &&
      cache.isCached(id) &&
      player.sequenceSources[index] == fileFor(id);

  Future<void> download(String id) async {
    final reachable = serverReachable;
    serverReachable = true;
    await cache.prefetch(id, urlFor(id));
    serverReachable = reachable;
  }

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    cacheDir = await Directory.systemTemp.createTemp('gapless_test');
    serverReachable = true;
    downloadGate = null;

    mockApi = MockSubsonicApi();
    mockSettings = MockSettingsService();
    player = MockAudioPlayer();

    when(mockSettings.replayGainMode).thenReturn(ReplayGainMode.track);
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
    )).thenAnswer((invocation) {
      final gain = invocation.namedArguments[#trackGain] as double;
      return gain == -6.0 ? 0.5 : 0.7;
    });

    when(mockApi.getStreamUrl(any)).thenAnswer(
        (invocation) => urlFor(invocation.positionalArguments.first as String));

    cache = AudioCache(
      client: MockClient((_) async {
        await downloadGate?.future;
        return serverReachable
            ? http.Response.bytes([1, 2, 3], 200,
                headers: {'content-type': 'audio/mpeg'})
            : http.Response('offline', 503);
      }),
      directoryProvider: () async => cacheDir,
    );

    service = AudioPlayerService(mockApi, mockSettings,
        audioPlayer: player, audioCache: cache);
  });

  tearDown(() async {
    service.dispose();
    cache.dispose();
    await player.dispose();
    await cacheDir.delete(recursive: true);
  });

  group('queue', () {
    test('hands the whole playlist to the player', () async {
      serverReachable = false;

      await service.playAlbum(albumOf(3));

      expect(
          player.sequenceSources, [urlFor('s1'), urlFor('s2'), urlFor('s3')]);
      expect(player.currentIndex, 0);
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('plays tracks that are already downloaded from the cache', () async {
      await download('s2');
      serverReachable = false;

      await service.playAlbum(albumOf(3));

      expect(
          player.sequenceSources, [urlFor('s1'), fileFor('s2'), urlFor('s3')]);
    });

    test('swaps the next three tracks for their downloads', () async {
      await service.playAlbum(albumOf(5));
      await until(() => playsFromCache(3, 's4'), 's4 plays from the cache');

      expect(player.sequenceSources, [
        urlFor('s1'),
        fileFor('s2'),
        fileFor('s3'),
        fileFor('s4'),
        urlFor('s5'),
      ]);
      // Positions up to the current track never shift
      expect(player.currentIndex, 0);
      expect(service.currentIndex, 0);
    });

    test('leaves the next track alone right before the current one ends',
        () async {
      downloadGate = Completer();
      await service.playAlbum(albumOf(3));
      player.simulatePositionChange(const Duration(minutes: 2, seconds: 55));
      await Future.delayed(const Duration(milliseconds: 20));

      downloadGate!.complete();
      await until(() => playsFromCache(2, 's3'), 's3 plays from the cache');

      expect(player.sequenceSources[1], urlFor('s2'));
    });
  });

  group('transition', () {
    test('follows the player to the next track without reloading', () async {
      await service.playAlbum(albumOf(3));
      await until(() => playsFromCache(1, 's2'), 's2 plays from the cache');

      player.simulateTrackTransition();
      await until(() => service.currentSong?.id == 's2', 'the service follows');

      expect(service.currentIndex, 1);
      expect(service.totalDuration, const Duration(minutes: 4));
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('downloads further ahead after moving on', () async {
      await service.playAlbum(albumOf(5));
      await until(() => playsFromCache(3, 's4'), 's4 plays from the cache');

      player.simulateTrackTransition();
      await until(() => playsFromCache(4, 's5'), 's5 plays from the cache');

      expect(player.currentIndex, 1);
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('ignores repeated and late index events', () async {
      await service.playAlbum(albumOf(4));
      await until(() => playsFromCache(3, 's4'), 's4 plays from the cache');
      player.simulateTrackTransition();
      await until(() => service.currentSong?.id == 's2', 'the service follows');

      for (final index in [1, 0, 1, 1]) {
        player.simulateIndexEvent(index);
        await Future.delayed(const Duration(milliseconds: 20));
      }

      expect(service.currentSong?.id, 's2');
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('scrobbles the finished track and reports the new one', () async {
      await service.playAlbum(albumOf(2));

      player.simulateTrackTransition();
      // The scrobble queue sends requests asynchronously, 100 ms apart
      await Future.delayed(const Duration(milliseconds: 500));

      verify(mockApi.scrobbleSubmission('s1', playedAt: anyNamed('playedAt')))
          .called(1);
      verify(mockApi.scrobbleNowPlaying('s2')).called(1);
    });

    test('applies the new track\'s ReplayGain', () async {
      await service.playAlbum(album([song('s1'), song('s2', gain: -3.0)]));
      expect(player.volumes.last, 0.5);

      player.simulateTrackTransition();
      await until(() => player.volumes.last == 0.7, 'the volume changes');
    });

    test('stops after the last track', () async {
      await service.playAlbum(albumOf(2));
      player.simulateTrackTransition();
      await until(() => service.currentSong?.id == 's2', 'the service follows');

      player.simulateCompletion();
      await Future.delayed(const Duration(milliseconds: 20));

      expect(service.currentIndex, 1);
      expect(service.playbackState, PlaybackState.stopped);
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('does not cut a track short near its end', () async {
      await service.playAlbum(albumOf(3));

      player.simulatePositionChange(
          const Duration(minutes: 2, seconds: 59, milliseconds: 800));
      await Future.delayed(const Duration(milliseconds: 20));

      expect(service.currentIndex, 0);
      expect(player.loadedSources, [urlFor('s1')]);
    });
  });

  group('offline', () {
    test('continues at the next downloaded track when the next one fails',
        () async {
      await download('s3');
      serverReachable = false;
      await service.playAlbum(albumOf(3));
      player.failingUrls.add(urlFor('s2'));

      player.simulateTrackTransition();
      await until(() => service.currentIndex == 2, 'playback continues at s3');

      expect(player.loadedSources.last, fileFor('s3'));
      expect(service.playbackState, PlaybackState.playing);
    });

    test('continues at the next downloaded track when a stream breaks off',
        () async {
      await download('s3');
      serverReachable = false;
      await service.playAlbum(albumOf(3));

      player.simulateLoadError();
      await until(() => service.currentIndex == 2, 'playback continues at s3');

      expect(player.loadedSources.last, fileFor('s3'));
    });

    test('stops when nothing ahead is downloaded, and play() tries again',
        () async {
      serverReachable = false;
      await service.playAlbum(albumOf(2));
      player.failingUrls.add(urlFor('s2'));

      player.simulateTrackTransition();
      await until(() => service.playbackState == PlaybackState.stopped,
          'playback stops');
      expect(service.currentSong?.id, 's2');

      player.failingUrls.clear();
      await service.play();
      await until(() => service.playbackState == PlaybackState.playing,
          'playback resumes');

      expect(player.loadedSources.last, urlFor('s2'));
      expect(service.currentIndex, 1);
    });
  });

  group('manual skips', () {
    test('next moves within the queue', () async {
      await service.playAlbum(albumOf(3));
      await until(() => playsFromCache(2, 's3'), 's3 plays from the cache');
      await Future.delayed(pastSkipDebounce);

      await service.next();

      expect(service.currentIndex, 1);
      expect(player.currentIndex, 1);
      expect(player.loadedSources, [urlFor('s1'), fileFor('s2')]);
      expect(player.sequenceSources.length, 3);
    });

    test('the player moves on normally after previous', () async {
      await service.playAlbum(albumOf(3));
      await Future.delayed(pastSkipDebounce);
      await service.next();
      await Future.delayed(pastSkipDebounce);
      await service.previous();
      expect(service.currentIndex, 0);

      player.simulateTrackTransition();
      await until(() => service.currentIndex == 1, 'the service follows');
    });
  });
}
