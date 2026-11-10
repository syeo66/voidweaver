import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/playback_persistence.dart';
import 'package:voidweaver/services/settings_service.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:voidweaver/services/replaygain_reader.dart';

import '../test_helpers/fake_audio_cache.dart';
import '../test_helpers/mock_api.dart';
import '../test_helpers/mocks.mocks.dart';
import '../test_helpers/mock_audio_player.dart';

void main() {
  group('Playback restore', () {
    late AudioPlayerService service;
    late MockSubsonicApi mockApi;
    late MockSettingsService mockSettingsService;
    late MockAudioPlayer mockAudioPlayer;
    late Directory storage;

    final song = Song(
      id: 'song1',
      title: 'Test Song',
      artist: 'Test Artist',
      album: 'Test Album',
      duration: 300, // 5 minutes
    );

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    setUp(() async {
      storage = await Directory.systemTemp.createTemp('restore');
      mockApi = newMockApi();
      mockSettingsService = MockSettingsService();
      mockAudioPlayer = MockAudioPlayer();

      when(mockSettingsService.replayGainMode).thenReturn(ReplayGainMode.off);
      when(mockSettingsService.replayGainPreamp).thenReturn(0.0);
      when(mockSettingsService.replayGainFallbackGain).thenReturn(0.0);
      when(mockSettingsService.replayGainPreventClipping).thenReturn(true);
      when(mockSettingsService.scrobbleMinPlayTimeMinutes).thenReturn(2.0);
      when(mockSettingsService.scrobbleThresholdPercent).thenReturn(50.0);
      when(
        mockSettingsService.calculateVolumeAdjustment(
          trackGain: anyNamed('trackGain'),
          albumGain: anyNamed('albumGain'),
          trackPeak: anyNamed('trackPeak'),
          albumPeak: anyNamed('albumPeak'),
          fromAlbum: anyNamed('fromAlbum'),
        ),
      ).thenReturn(1.0);
      when(mockApi.getStreamUrl(any)).thenReturn('https://example.com/stream');
      when(mockApi.readReplayGain(any))
          .thenAnswer((_) async => const ReplayGainData());
    });

    tearDown(() async {
      service.dispose();
      await mockAudioPlayer.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await storage.delete(recursive: true);
    });

    Future<PlaybackPersistenceService> savedAt(
      Duration position, {
      List<Song>? playlist,
    }) async {
      final saved = PersistedPlaybackState(
        playlist: playlist ?? [song],
        currentIndex: 0,
        currentPosition: position,
        isPlaying: true,
        lastUpdated: DateTime.now(),
      );
      SharedPreferences.setMockInitialValues({});
      final writer = PlaybackPersistenceService(directory: storage);
      await writer.initialize();
      await writer.savePlaybackState(saved);
      // A new instance, as on the next start
      final persistence = PlaybackPersistenceService(directory: storage);
      await persistence.initialize();
      return persistence;
    }

    Future<void> restoreAt(Duration position) async {
      service = AudioPlayerService(
        mockApi,
        mockSettingsService,
        audioPlayer: mockAudioPlayer,
        persistence: await savedAt(position),
        clock: mockAudioPlayer.clock,
      );
      expect(await service.restorePlaybackState(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    test('Play pressed while the restored song fails to load reports it, '
        'and Play again loads it at the restored position', () async {
      service = AudioPlayerService(
        mockApi,
        mockSettingsService,
        audioPlayer: mockAudioPlayer,
        persistence: await savedAt(const Duration(seconds: 30)),
        clock: mockAudioPlayer.clock,
      );
      final errors = <String>[];
      service.playbackErrors.listen(errors.add);
      mockAudioPlayer.failingUrls.add('https://example.com/stream');
      mockAudioPlayer.loadGate = Completer();

      final restoring = service.restorePlaybackState();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await service.play();
      mockAudioPlayer.loadGate!.complete();
      await restoring;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(errors, hasLength(1));
      expect(errors.single, contains('Test Song'));
      expect(mockAudioPlayer.playing, isFalse);

      // The server is back
      mockAudioPlayer.failingUrls.clear();
      mockAudioPlayer.loadGate = null;
      await service.play();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(mockAudioPlayer.position, const Duration(seconds: 30));
      expect(mockAudioPlayer.playing, isTrue);
      expect(errors, hasLength(1));
    });

    test('Play pressed while the restored song fails to load continues at a '
        'later downloaded track, unreported', () async {
      final cache = FakeAudioCache()..cached.add('song3');
      mockAudioPlayer = MockAudioPlayer(isCached: cache.isCachedKey);
      when(mockApi.getStreamUrl(any)).thenAnswer(
        (invocation) =>
            'https://example.com/stream?id=${invocation.positionalArguments.first}',
      );
      final songs = [
        song,
        for (final id in ['song2', 'song3'])
          Song(id: id, title: id, artist: 'Artist', album: 'Album'),
      ];
      service = AudioPlayerService(
        mockApi,
        mockSettingsService,
        audioPlayer: mockAudioPlayer,
        audioCache: cache,
        persistence: await savedAt(
          const Duration(seconds: 30),
          playlist: songs,
        ),
        clock: mockAudioPlayer.clock,
      );
      final errors = <String>[];
      service.playbackErrors.listen(errors.add);
      mockAudioPlayer.failingUrls.addAll([
        for (final id in ['song1', 'song2', 'song3'])
          'https://example.com/stream?id=$id',
      ]);
      mockAudioPlayer.loadGate = Completer();

      final restoring = service.restorePlaybackState();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await service.play();
      mockAudioPlayer.loadGate!.complete();
      await restoring;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(errors, isEmpty);
      expect(service.currentIndex, 2);
      expect(mockAudioPlayer.currentIndex, 2);
      expect(mockAudioPlayer.playing, isTrue);
    });

    test('a restore that fails without Play pressed reports nothing', () async {
      service = AudioPlayerService(
        mockApi,
        mockSettingsService,
        audioPlayer: mockAudioPlayer,
        persistence: await savedAt(const Duration(seconds: 30)),
        clock: mockAudioPlayer.clock,
      );
      final errors = <String>[];
      service.playbackErrors.listen(errors.add);
      mockAudioPlayer.failingUrls.add('https://example.com/stream');

      await service.restorePlaybackState();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(errors, isEmpty);
      expect(service.currentPosition, const Duration(seconds: 30));
    });

    test('playhead shows the restored position', () async {
      await restoreAt(const Duration(seconds: 90));

      expect(service.currentPosition, const Duration(seconds: 90));

      await service.play();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(service.currentPosition, const Duration(seconds: 90));
    });

    test('restored song is scrobbled once it passes the threshold', () async {
      await restoreAt(const Duration(seconds: 60));
      clearInteractions(mockApi);

      await service.play();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      verify(mockApi.scrobbleNowPlaying('song1')).called(1);

      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 150));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      verify(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      ).called(1);

      mockAudioPlayer.simulateCompletion();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      verifyNever(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      );
    });

    test(
      'restored song already past the threshold is not scrobbled again',
      () async {
        await restoreAt(const Duration(seconds: 200));
        clearInteractions(mockApi);

        await service.play();
        mockAudioPlayer.simulatePositionChange(const Duration(seconds: 250));
        await Future<void>.delayed(const Duration(milliseconds: 250));
        mockAudioPlayer.simulateCompletion();
        await Future<void>.delayed(const Duration(milliseconds: 250));

        verifyNever(
          mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
        );
      },
    );

    test('plays the restored song when started for a media button', () async {
      mockAudioPlayer.resumeRequested = true;
      await restoreAt(const Duration(seconds: 90));
      expect(mockAudioPlayer.playing, isFalse);

      await service.resumeIfRequested();
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(mockAudioPlayer.playing, isTrue);
      expect(service.currentPosition, const Duration(seconds: 90));
      verify(mockApi.scrobbleNowPlaying('song1')).called(1);
    });

    test('stays paused when not started for a media button', () async {
      await restoreAt(const Duration(seconds: 90));

      await service.resumeIfRequested();
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(mockAudioPlayer.playing, isFalse);
    });

    test('playback started while restoring replaces the saved queue', () async {
      // Restoring waits for the saved song's ReplayGain tags
      final tags = Completer<ReplayGainData>();
      when(mockApi.readReplayGain('song1')).thenAnswer((_) => tags.future);
      service = AudioPlayerService(
        mockApi,
        mockSettingsService,
        audioPlayer: mockAudioPlayer,
        persistence: await savedAt(const Duration(seconds: 90)),
        audioCache: FakeAudioCache(),
      );
      final restoring = service.restorePlaybackState();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await service.playSong(
        Song(id: 'song2', title: 'Other', artist: 'Other', album: 'Other'),
      );
      tags.complete(const ReplayGainData());

      expect(await restoring, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(service.playlist.map((s) => s.id), ['song2']);
      expect(service.currentSong?.id, 'song2');
      expect(mockAudioPlayer.playing, isTrue);
      expect(service.playbackState, PlaybackState.playing);
    });

    test(
      'a single song replaces the saved source of the album before it',
      () async {
        SharedPreferences.setMockInitialValues({});
        final persistence = PlaybackPersistenceService(directory: storage);
        await persistence.initialize();
        service = AudioPlayerService(
          mockApi,
          mockSettingsService,
          audioPlayer: mockAudioPlayer,
          persistence: persistence,
        );

        await service.playAlbum(
          Album(
            id: 'album1',
            name: 'Test Album',
            artist: 'Test Artist',
            songCount: 1,
            songs: [song],
          ),
        );
        await service.playSong(
          Song(id: 'song2', title: 'Other', artist: 'Other', album: 'Other'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));

        final saved = await persistence.loadPlaybackState();
        expect(saved!.playlistSource, 'song');
        expect(saved.sourceId, 'song2');
      },
    );

    test(
      'the player reports the position less often while the app is hidden',
      () async {
        service = AudioPlayerService(
          mockApi,
          mockSettingsService,
          audioPlayer: mockAudioPlayer,
        );

        service.setVisible(false);
        service.setVisible(true);
        await Future<void>.delayed(Duration.zero);

        expect(mockAudioPlayer.positionIntervals, [
          const Duration(seconds: 1),
          const Duration(milliseconds: 200),
        ]);
      },
    );
  });
}
