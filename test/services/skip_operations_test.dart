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
import 'skip_operations_test.mocks.dart';

@GenerateMocks([SubsonicApi, SettingsService])
void main() {
  // Skips within this window of the previous one are ignored by the service
  const pastSkipDebounce = Duration(milliseconds: 250);

  late Directory cacheDir;
  late MockSubsonicApi mockApi;
  late MockSettingsService mockSettings;
  late MockAudioPlayer player;
  late AudioCache cache;
  // Whether the fake server delivers audio; off, preloads of upcoming
  // tracks fail as if the network were down
  late bool serverReachable;
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
    cacheDir = await Directory.systemTemp.createTemp('skip_ops_test');

    mockApi = MockSubsonicApi();
    mockSettings = MockSettingsService();
    player = MockAudioPlayer();

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

    serverReachable = false;
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
      serverReachable = true;
      await cache.prefetch('s3', urlFor('s3'));
      serverReachable = false;

      await service.playAlbum(album(3));
      await Future.delayed(pastSkipDebounce);
      player.failingUrls.add(urlFor('s2'));

      await service.next();

      expect(service.currentIndex, 2);
      expect(service.currentSong?.id, 's3');
      expect(player.loadedSources.last, startsWith('file:'));
    });

    test('stays on the current track when nothing later can load', () async {
      await service.playAlbum(album(2));
      await Future.delayed(pastSkipDebounce);
      player.failingUrls.add(urlFor('s2'));

      await service.next();

      expect(service.isSkipOperationInProgress, isFalse);
      expect(player.loadedSources, [urlFor('s1')]);
    });
  });

  group('previous()', () {
    test('does nothing on the first track', () async {
      await service.playAlbum(album(3));

      await service.previous();

      expect(service.currentIndex, 0);
      expect(service.hasPrevious, isFalse);
      expect(player.loadedSources, [urlFor('s1')]);
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

    test('advances only once for duplicate completion events', () async {
      await service.playAlbum(album(3));

      player.simulateCompletion();
      player.simulateCompletion();
      await settle();

      expect(service.currentIndex, 1);
      expect(player.loadedSources, [urlFor('s1'), urlFor('s2')]);
    });

    test('stops at the end of the playlist', () async {
      await service.playAlbum(album(1));

      player.simulateCompletion();
      await settle();

      expect(service.currentIndex, 0);
      expect(service.playbackState, PlaybackState.stopped);
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
