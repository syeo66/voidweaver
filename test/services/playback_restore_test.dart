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
import 'package:voidweaver/services/scrobble_queue.dart';

import '../test_helpers/fake_audio_cache.dart';
import '../test_helpers/mock_api.dart';
import '../test_helpers/mocks.mocks.dart';
import '../test_helpers/mock_audio_player.dart';
import '../test_helpers/waiting.dart';

void main() {
  group('Playback restore', () {
    late AudioPlayerService service;
    late MockSubsonicApi mockApi;
    late MockSettingsService mockSettingsService;
    late MockAudioPlayer mockAudioPlayer;
    late Directory storage;
    late ScrobbleQueue scrobbleQueue;
    // Every persistence of the test, see settle()
    final persistences = <PlaybackPersistenceService>[];

    PlaybackPersistenceService newPersistenceAt(
      Directory directory, {
      Duration positionSaveInterval = const Duration(seconds: 5),
    }) {
      final persistence = PlaybackPersistenceService(
        directory: directory,
        positionSaveInterval: positionSaveInterval,
      );
      persistences.add(persistence);
      return persistence;
    }

    /// Lets the service finish what it's doing: the player's operations,
    /// the scrobble queue's requests (sent 100 ms apart), and the saves
    /// they started (not a timed save still waiting)
    Future<void> settle() async {
      await pumpUntil(
        () =>
            service.pendingPlayerOps == 0 &&
            service.startsInProgress == 0 &&
            scrobbleQueue.queueSize == 0,
        reason: 'the player and the scrobble queue to be done',
      );
      for (final persistence in persistences) {
        await savesWritten(persistence);
      }
    }

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
      persistences.clear();
      mockApi = newMockApi();
      scrobbleQueue = ScrobbleQueue(mockApi);
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
      // The position save that dispose() writes, before its directory goes
      for (final persistence in persistences) {
        await allSavesWritten(persistence);
      }
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
      final writer = newPersistenceAt(storage);
      await writer.initialize();
      await writer.savePlaybackState(saved);
      // A new instance, as on the next start
      final persistence = newPersistenceAt(storage);
      await persistence.initialize();
      return persistence;
    }

    /// Waits until the player loads a queue (held at its loadGate).
    Future<void> untilLoading() => pumpUntil(
      () => mockAudioPlayer.loadedSources.isNotEmpty,
      reason: 'the restored queue to load',
    );

    Future<void> restoreAt(Duration position) async {
      service = AudioPlayerService(
        mockApi,
        mockSettingsService,
        audioPlayer: mockAudioPlayer,
        scrobbleQueue: scrobbleQueue,
        persistence: await savedAt(position),
        clock: mockAudioPlayer.clock,
      );
      expect(await service.restorePlaybackState(), isTrue);
      await settle();
    }

    test('Play pressed while the restored song fails to load reports it, '
        'and Play again loads it at the restored position', () async {
      service = AudioPlayerService(
        mockApi,
        mockSettingsService,
        audioPlayer: mockAudioPlayer,
        scrobbleQueue: scrobbleQueue,
        persistence: await savedAt(const Duration(seconds: 30)),
        clock: mockAudioPlayer.clock,
      );
      final errors = <String>[];
      service.playbackErrors.listen(errors.add);
      mockAudioPlayer.failingUrls.add('https://example.com/stream');
      mockAudioPlayer.loadGate = Completer();

      final restoring = service.restorePlaybackState();
      // Reading the saved state touches the disk: wait for the load itself,
      // not a fixed time, or Play may come before there is a queue to play
      await untilLoading();
      await service.play();
      mockAudioPlayer.loadGate!.complete();
      await restoring;
      await settle();

      expect(errors, hasLength(1));
      expect(errors.single, contains('Test Song'));
      expect(mockAudioPlayer.playing, isFalse);

      // The server is back
      mockAudioPlayer.failingUrls.clear();
      mockAudioPlayer.loadGate = null;
      await service.play();
      await settle();

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
        scrobbleQueue: scrobbleQueue,
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
      // Reading the saved state touches the disk: wait for the load itself,
      // not a fixed time, or Play may come before there is a queue to play
      await untilLoading();
      await service.play();
      mockAudioPlayer.loadGate!.complete();
      await restoring;
      await settle();

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
        scrobbleQueue: scrobbleQueue,
        persistence: await savedAt(const Duration(seconds: 30)),
        clock: mockAudioPlayer.clock,
      );
      final errors = <String>[];
      service.playbackErrors.listen(errors.add);
      mockAudioPlayer.failingUrls.add('https://example.com/stream');

      await service.restorePlaybackState();
      await settle();

      expect(errors, isEmpty);
      expect(service.currentPosition, const Duration(seconds: 30));
    });

    test('playhead shows the restored position', () async {
      await restoreAt(const Duration(seconds: 90));

      expect(service.currentPosition, const Duration(seconds: 90));

      await service.play();
      await settle();
      expect(service.currentPosition, const Duration(seconds: 90));
    });

    test('restored song is scrobbled once it passes the threshold', () async {
      await restoreAt(const Duration(seconds: 60));
      clearInteractions(mockApi);

      await service.play();
      await settle();
      verify(mockApi.scrobbleNowPlaying('song1')).called(1);

      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 150));
      await settle();
      verify(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      ).called(1);

      mockAudioPlayer.simulateCompletion();
      await settle();
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
        await settle();
        mockAudioPlayer.simulateCompletion();
        await settle();

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
      await settle();

      expect(mockAudioPlayer.playing, isTrue);
      expect(service.currentPosition, const Duration(seconds: 90));
      verify(mockApi.scrobbleNowPlaying('song1')).called(1);
    });

    test('stays paused when not started for a media button', () async {
      await restoreAt(const Duration(seconds: 90));

      await service.resumeIfRequested();
      await settle();

      expect(mockAudioPlayer.playing, isFalse);
    });

    test('playback started while restoring replaces the saved queue', () async {
      // Restoring waits for the saved song's ReplayGain tags
      final tags = Completer<ReplayGainData>();
      var reading = false;
      when(mockApi.readReplayGain('song1')).thenAnswer((_) {
        reading = true;
        return tags.future;
      });
      service = AudioPlayerService(
        mockApi,
        mockSettingsService,
        audioPlayer: mockAudioPlayer,
        scrobbleQueue: scrobbleQueue,
        persistence: await savedAt(const Duration(seconds: 90)),
        audioCache: FakeAudioCache(),
      );
      final restoring = service.restorePlaybackState();
      await pumpUntil(() => reading, reason: 'the restore to read the tags');

      await service.playSong(
        Song(id: 'song2', title: 'Other', artist: 'Other', album: 'Other'),
      );
      tags.complete(const ReplayGainData());

      expect(await restoring, isFalse);
      await settle();
      expect(service.playlist.map((s) => s.id), ['song2']);
      expect(service.currentSong?.id, 'song2');
      expect(mockAudioPlayer.playing, isTrue);
      expect(service.playbackState, PlaybackState.playing);
    });

    group('saving the position without playback', () {
      Future<PlaybackPersistenceService> newPersistence() async {
        SharedPreferences.setMockInitialValues({});
        final persistence = newPersistenceAt(
          storage,
          positionSaveInterval: const Duration(milliseconds: 20),
        );
        await persistence.initialize();
        return persistence;
      }

      Future<Duration?> savedPosition() async {
        // A new instance, as on the next start
        final reader = PlaybackPersistenceService(directory: storage);
        await reader.initialize();
        return (await reader.loadPlaybackState())?.currentPosition;
      }

      test('a seek while paused is saved', () async {
        service = AudioPlayerService(
          mockApi,
          mockSettingsService,
          audioPlayer: mockAudioPlayer,
          scrobbleQueue: scrobbleQueue,
          persistence: await newPersistence(),
          clock: mockAudioPlayer.clock,
        );
        await service.playSong(song);
        await service.pause();
        await settle();

        await service.seekTo(const Duration(seconds: 180));

        // Saved by the timed save (20 ms)
        await pumpUntil(
          () async => await savedPosition() == const Duration(seconds: 180),
          reason: 'the seek to be saved',
        );
      });

      test('a seek on a queue that is not loaded is saved', () async {
        service = AudioPlayerService(
          mockApi,
          mockSettingsService,
          audioPlayer: mockAudioPlayer,
          scrobbleQueue: scrobbleQueue,
          persistence: await newPersistence(),
          clock: mockAudioPlayer.clock,
        );
        await service.playSong(song);
        await service.stop();
        expect(service.needsSourceReload, isTrue);

        await service.seekTo(const Duration(seconds: 90));

        // Saved by the timed save (20 ms)
        await pumpUntil(
          () async => await savedPosition() == const Duration(seconds: 90),
          reason: 'the seek to be saved',
        );
      });

      test('pausing saves the position it stopped at', () async {
        // The timed save is far off: only the pause can write it
        SharedPreferences.setMockInitialValues({});
        final persistence = newPersistenceAt(storage);
        await persistence.initialize();
        service = AudioPlayerService(
          mockApi,
          mockSettingsService,
          audioPlayer: mockAudioPlayer,
          scrobbleQueue: scrobbleQueue,
          persistence: persistence,
          clock: mockAudioPlayer.clock,
        );
        await service.playSong(song);
        mockAudioPlayer.simulatePositionChange(const Duration(seconds: 42));
        await settle();

        await service.pause();
        await settle();

        expect(await savedPosition(), const Duration(seconds: 42));
      });
    });

    test(
      'a single song replaces the saved source of the album before it',
      () async {
        SharedPreferences.setMockInitialValues({});
        final persistence = newPersistenceAt(storage);
        await persistence.initialize();
        service = AudioPlayerService(
          mockApi,
          mockSettingsService,
          audioPlayer: mockAudioPlayer,
          scrobbleQueue: scrobbleQueue,
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
        await settle();

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
          scrobbleQueue: scrobbleQueue,
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
