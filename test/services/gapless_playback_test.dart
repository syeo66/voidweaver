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
  late Directory cacheDir;
  late MockSubsonicApi mockApi;
  late MockSettingsService mockSettings;
  late MockAudioPlayer player;
  late AudioCache cache;
  late AudioPlayerService service;
  late bool serverReachable;

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

  /// Waits until [condition] holds, failing after a second.
  Future<void> until(bool Function() condition, String description) async {
    for (var i = 0; i < 100; i++) {
      if (condition()) return;
      await Future.delayed(const Duration(milliseconds: 10));
    }
    fail('Timed out waiting until $description');
  }

  bool nextQueued() => player.sequenceSources.length == 2;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    cacheDir = await Directory.systemTemp.createTemp('gapless_test');
    serverReachable = true;

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
      client: MockClient((_) async => serverReachable
          ? http.Response.bytes([1, 2, 3], 200,
              headers: {'content-type': 'audio/mpeg'})
          : http.Response('offline', 503)),
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

  group('queueing', () {
    test('appends the next track to the player once it is cached', () async {
      await service.playAlbum(albumOf(3));
      await until(nextQueued, 'the next track is queued');

      expect(player.sequenceSources.first, urlFor('s1'));
      expect(player.sequenceSources.last,
          'file:${cache.getCachedFile('s2')!.path}');
    });

    test('does not queue a track that is not cached', () async {
      serverReachable = false;

      await service.playAlbum(albumOf(3));
      await Future.delayed(const Duration(milliseconds: 100));

      expect(player.sequenceSources, [urlFor('s1')]);
    });

    test('does not queue anything on the last track', () async {
      await service.playAlbum(albumOf(1));
      await Future.delayed(const Duration(milliseconds: 100));

      expect(player.sequenceSources, [urlFor('s1')]);
    });
  });

  group('transition', () {
    test('follows the player to the next track without reloading', () async {
      await service.playAlbum(albumOf(3));
      await until(nextQueued, 'the next track is queued');

      final s2File = 'file:${cache.getCachedFile('s2')!.path}';
      player.simulateTrackTransition();
      await until(() => player.sequenceSources.first == s2File,
          'the finished track is dropped');

      expect(service.currentIndex, 1);
      expect(service.currentSong?.id, 's2');
      expect(service.totalDuration, const Duration(minutes: 4));
      // Only the first track was loaded explicitly
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('queues the track after the new one', () async {
      await service.playAlbum(albumOf(3));
      await until(nextQueued, 'the next track is queued');

      player.simulateTrackTransition();
      await until(
          () =>
              nextQueued() &&
              player.sequenceSources.last ==
                  'file:${cache.getCachedFile('s3')?.path}',
          's3 is queued after s2');

      expect(player.currentIndex, 0);
    });

    test('scrobbles the finished track and reports the new one', () async {
      await service.playAlbum(albumOf(2));
      await until(nextQueued, 'the next track is queued');

      player.simulateTrackTransition();
      // The scrobble queue sends requests asynchronously
      await Future.delayed(const Duration(milliseconds: 200));

      verify(mockApi.scrobbleSubmission('s1', playedAt: anyNamed('playedAt')))
          .called(1);
      verify(mockApi.scrobbleNowPlaying('s2')).called(1);
    });

    test('applies the new track\'s ReplayGain', () async {
      await service.playAlbum(album([song('s1'), song('s2', gain: -3.0)]));
      await until(nextQueued, 'the next track is queued');
      expect(player.volumes.last, 0.5);

      player.simulateTrackTransition();
      await until(() => player.volumes.last == 0.7, 'the volume changes');
    });

    test('stops after the last track as before', () async {
      await service.playAlbum(albumOf(2));
      await until(nextQueued, 'the next track is queued');
      player.simulateTrackTransition();
      await until(() => player.sequenceSources.length == 1,
          'the finished track is dropped');

      player.simulateCompletion();
      await Future.delayed(const Duration(milliseconds: 20));

      expect(service.currentIndex, 1);
      expect(service.playbackState, PlaybackState.stopped);
      expect(player.loadedSources, [urlFor('s1')]);
    });
  });

  group('completion fallback', () {
    test('does not cut the track short when the next one is queued', () async {
      await service.playAlbum(albumOf(3));
      await until(nextQueued, 'the next track is queued');

      player.simulatePositionChange(
          const Duration(minutes: 2, seconds: 59, milliseconds: 800));
      await Future.delayed(const Duration(milliseconds: 20));

      expect(service.currentIndex, 0);
      expect(player.loadedSources, [urlFor('s1')]);
    });

    test('still advances near the end when nothing is queued', () async {
      serverReachable = false;
      await service.playAlbum(albumOf(3));
      serverReachable = true;

      player.simulatePositionChange(
          const Duration(minutes: 2, seconds: 59, milliseconds: 800));
      await until(() => service.currentIndex == 1, 'the player advances');

      expect(player.loadedSources, [urlFor('s1'), urlFor('s2')]);
    });
  });

  group('manual skips', () {
    test('replace the queued sequence', () async {
      await service.playAlbum(albumOf(3));
      await until(nextQueued, 'the next track is queued');
      await Future.delayed(const Duration(milliseconds: 250));

      await service.next();
      await until(
          () =>
              nextQueued() &&
              player.sequenceSources.last ==
                  'file:${cache.getCachedFile('s3')?.path}',
          's3 is queued after s2');

      expect(service.currentIndex, 1);
      expect(
          player.loadedSources.last, 'file:${cache.getCachedFile('s2')!.path}');

      player.simulateTrackTransition();
      await until(() => service.currentIndex == 2, 'the player moves to s3');
    });

    test('previous drops the queued track of the old position', () async {
      await service.playAlbum(albumOf(3));
      await until(nextQueued, 'the next track is queued');
      await Future.delayed(const Duration(milliseconds: 250));
      await service.next();
      await Future.delayed(const Duration(milliseconds: 250));

      await service.previous();
      await until(
          () =>
              nextQueued() &&
              player.sequenceSources.last ==
                  'file:${cache.getCachedFile('s2')?.path}',
          's2 is queued after s1');

      expect(service.currentIndex, 0);
    });
  });
}
