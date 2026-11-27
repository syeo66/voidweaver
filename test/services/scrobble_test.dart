import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver_player/voidweaver_player.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:voidweaver/services/settings_service.dart';
import 'package:voidweaver/services/replaygain_reader.dart';
import 'package:voidweaver/services/scrobble_queue.dart';

import '../test_helpers/mock_api.dart';
import '../test_helpers/mocks.mocks.dart';
import '../test_helpers/mock_audio_player.dart';
import '../test_helpers/waiting.dart';

void main() {
  group('Scrobble Tests', () {
    late AudioPlayerService audioPlayerService;
    late MockSubsonicApi mockApi;
    late MockSettingsService mockSettingsService;
    late MockAudioPlayer mockAudioPlayer;
    late ScrobbleQueue scrobbleQueue;

    /// Lets the service act on what the player reported, and the scrobble
    /// queue send what it got (100 ms apart)
    Future<void> settle() => pumpUntil(
      () =>
          audioPlayerService.pendingPlayerOps == 0 &&
          audioPlayerService.startsInProgress == 0 &&
          scrobbleQueue.queueSize == 0,
      reason: 'the player and the scrobble queue to be done',
    );

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    setUp(() {
      mockApi = newMockApi();
      mockSettingsService = MockSettingsService();
      mockAudioPlayer = MockAudioPlayer();
      SharedPreferences.setMockInitialValues({});
      scrobbleQueue = ScrobbleQueue(mockApi);

      // Mock settings service methods
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

      // Mock API methods
      when(mockApi.getStreamUrl(any)).thenReturn('https://example.com/stream');
      when(mockApi.readReplayGain(any))
          .thenAnswer((_) async => const ReplayGainData());

      audioPlayerService = AudioPlayerService(
        mockApi,
        mockSettingsService,
        audioPlayer: mockAudioPlayer,
        scrobbleQueue: scrobbleQueue,
        clock: mockAudioPlayer.clock,
      );
    });

    tearDown(() async {
      audioPlayerService.dispose();
      await mockAudioPlayer.dispose();
    });

    test('should send now playing notification when song starts', () async {
      // Create a test album with a song
      final album = Album(
        id: 'album1',
        name: 'Test Album',
        artist: 'Test Artist',
        songs: [
          Song(
            id: 'song1',
            title: 'Test Song',
            artist: 'Test Artist',
            album: 'Test Album',
            duration: 180, // 3 minutes
          ),
        ],
      );

      // Play the album
      await audioPlayerService.playAlbum(album);

      // Wait for async operations to complete
      await settle();

      // Verify now playing notification was sent
      verify(
        mockApi.scrobbleNowPlaying('song1', startedAt: anyNamed('startedAt')),
      ).called(1);
    });

    test('should scrobble song when it reaches 50% progress', () async {
      // Create a test album with a 4-minute song
      final album = Album(
        id: 'album1',
        name: 'Test Album',
        artist: 'Test Artist',
        songs: [
          Song(
            id: 'song1',
            title: 'Test Song',
            artist: 'Test Artist',
            album: 'Test Album',
            duration: 240, // 4 minutes
          ),
        ],
      );

      // Set up mock duration
      mockAudioPlayer.simulateDurationChange(const Duration(seconds: 240));

      // Play the album
      await audioPlayerService.playAlbum(album);
      await settle();

      // Reset the mock to clear the nowPlaying call
      clearInteractions(mockApi);

      // Simulate playback to 50% (2 minutes)
      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 120));
      await settle();

      // Verify scrobble was submitted
      verify(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      ).called(1);
    });

    test(
      'should scrobble song when it reaches 2 minutes on a short song',
      () async {
        // Create a test album with a 3-minute song (less than 4 minutes)
        final album = Album(
          id: 'album1',
          name: 'Test Album',
          artist: 'Test Artist',
          songs: [
            Song(
              id: 'song1',
              title: 'Test Song',
              artist: 'Test Artist',
              album: 'Test Album',
              duration: 180, // 3 minutes
            ),
          ],
        );

        // Set up mock duration
        mockAudioPlayer.simulateDurationChange(const Duration(seconds: 180));

        // Play the album
        await audioPlayerService.playAlbum(album);
        await settle();

        // Reset the mock to clear the nowPlaying call
        clearInteractions(mockApi);

        // Simulate playback to 2 minutes (which is > 50% for a 3-minute song)
        // So the 2-minute rule should trigger first
        mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 120));
        await settle();

        // Verify scrobble was submitted
        verify(
          mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
        ).called(1);
      },
    );

    test('should NOT scrobble song before reaching criteria', () async {
      // Create a test album with a 10-minute song
      final album = Album(
        id: 'album1',
        name: 'Test Album',
        artist: 'Test Artist',
        songs: [
          Song(
            id: 'song1',
            title: 'Test Song',
            artist: 'Test Artist',
            album: 'Test Album',
            duration: 600, // 10 minutes
          ),
        ],
      );

      // Set up mock duration
      mockAudioPlayer.simulateDurationChange(const Duration(seconds: 600));

      // Play the album
      await audioPlayerService.playAlbum(album);
      await settle();

      // Reset the mock to clear the nowPlaying call
      clearInteractions(mockApi);

      // Simulate playback to only 1 minute (less than 2 minutes and less than 50%)
      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 60));
      await settle();

      // Verify scrobble was NOT submitted
      verifyNever(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      );
    });

    test('should scrobble only once per song during playback', () async {
      // Create a test album with a 4-minute song
      final album = Album(
        id: 'album1',
        name: 'Test Album',
        artist: 'Test Artist',
        songs: [
          Song(
            id: 'song1',
            title: 'Test Song',
            artist: 'Test Artist',
            album: 'Test Album',
            duration: 240, // 4 minutes
          ),
        ],
      );

      // Set up mock duration
      mockAudioPlayer.simulateDurationChange(const Duration(seconds: 240));

      // Play the album
      await audioPlayerService.playAlbum(album);
      await settle();

      // Reset the mock to clear the nowPlaying call
      clearInteractions(mockApi);

      // Simulate playback past 50%
      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 120));
      await settle();

      // Continue playback (simulate more position updates)
      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 130));
      await settle();

      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 140));
      await settle();

      // Verify scrobble was submitted only once
      verify(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      ).called(1);
    });

    Album threeMinuteAlbum() => Album(
      id: 'album1',
      name: 'Test Album',
      artist: 'Test Artist',
      songs: [
        Song(
          id: 'song1',
          title: 'Test Song',
          artist: 'Test Artist',
          album: 'Test Album',
          duration: 180,
        ),
        Song(
          id: 'song2',
          title: 'Test Song 2',
          artist: 'Test Artist',
          album: 'Test Album',
          duration: 180,
        ),
      ],
    );

    test(
      'should scrobble a song played to its end at a 100% threshold',
      () async {
        when(mockSettingsService.scrobbleMinPlayTimeMinutes).thenReturn(10.0);
        when(mockSettingsService.scrobbleThresholdPercent).thenReturn(100.0);
        mockAudioPlayer.simulateDurationChange(const Duration(seconds: 180));
        await audioPlayerService.playAlbum(threeMinuteAlbum());
        await settle();
        clearInteractions(mockApi);

        // The last position update comes shortly before the end
        mockAudioPlayer.simulatePlayingTo(const Duration(milliseconds: 179800));
        await settle();
        verifyNever(
          mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')),
        );

        mockAudioPlayer.simulateCompletion();
        await settle();

        verify(
          mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
        ).called(1);
      },
    );

    test('should NOT scrobble a song seeked to its end', () async {
      mockAudioPlayer.simulateDurationChange(const Duration(seconds: 180));
      await audioPlayerService.playAlbum(threeMinuteAlbum());
      await settle();
      clearInteractions(mockApi);

      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 30));
      await settle();
      await audioPlayerService.seekTo(const Duration(seconds: 175));
      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 178));
      await settle();

      mockAudioPlayer.simulateCompletion();
      await settle();

      verifyNever(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      );
    });

    test('should NOT scrobble a song seeked to exactly its end', () async {
      // Like Media3: the seek completes on the next track. Its index event
      // waits until the seek is done; its position and duration don't. The
      // next track is long enough that its length, credited to this one,
      // would pass the threshold.
      mockAudioPlayer.seekToEndAdvancesTo = const Duration(minutes: 10);
      mockAudioPlayer.simulateDurationChange(const Duration(seconds: 180));
      await audioPlayerService.playAlbum(threeMinuteAlbum());
      await settle();
      clearInteractions(mockApi);

      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 10));
      await settle();
      await audioPlayerService.seekTo(const Duration(seconds: 180));
      await settle();

      expect(audioPlayerService.currentSong?.id, 'song2');
      expect(audioPlayerService.totalDuration, const Duration(minutes: 10));
      verifyNever(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      );
      expect(scrobbleQueue.queueSize, 0);
    });

    test('should NOT scrobble the last song seeked to its end', () async {
      mockAudioPlayer.simulateDurationChange(const Duration(seconds: 180));
      await audioPlayerService.playSong(
        Song(
          id: 'song1',
          title: 'Test Song',
          artist: 'Test Artist',
          album: 'Test Album',
          duration: 180,
        ),
      );
      await settle();
      clearInteractions(mockApi);

      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 10));
      await settle();
      await audioPlayerService.seekTo(const Duration(seconds: 180));
      mockAudioPlayer.simulateCompletion();
      await settle();

      verifyNever(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      );
    });

    test('should scrobble the next song once it has been heard', () async {
      mockAudioPlayer.seekToEndAdvancesTo = const Duration(minutes: 4);
      mockAudioPlayer.simulateDurationChange(const Duration(seconds: 180));
      await audioPlayerService.playAlbum(threeMinuteAlbum());
      await settle();
      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 10));
      await audioPlayerService.seekTo(const Duration(seconds: 180));
      await settle();
      clearInteractions(mockApi);

      // song2's position updates count again once it's followed
      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 125));
      await settle();

      verifyNever(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      );
      verify(
        mockApi.scrobbleSubmission('song2', playedAt: anyNamed('playedAt')),
      ).called(1);
    });

    group('while the player is on the next track before the service', () {
      Album album() => Album(
        id: 'album1',
        name: 'Test Album',
        artist: 'Test Artist',
        songs: [
          for (final id in ['song1', 'song2', 'song3'])
            Song(
              id: id,
              title: id,
              artist: 'Test Artist',
              album: 'Test Album',
              duration: 180,
            ),
        ],
      );

      late Completer<void> gate;
      late Future<void> seek;

      /// Plays song1 for 10 s, then seeks to its end: the player is on
      /// song2 and buffers there, and the seek waits at the gate.
      setUp(() async {
        mockAudioPlayer.seekToEndAdvancesTo = const Duration(minutes: 10);
        mockAudioPlayer.simulateDurationChange(const Duration(seconds: 180));
        await audioPlayerService.playAlbum(album());
        await settle();
        mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 10));
        await settle();
        clearInteractions(mockApi);
        gate = mockAudioPlayer.seekGate = Completer<void>();
        seek = audioPlayerService.seekTo(const Duration(seconds: 180));
        await pumpUntil(() => mockAudioPlayer.currentIndex == 1);
      });

      test('its updates are not the current track\'s', () async {
        mockAudioPlayer.simulatePositionChange(const Duration(seconds: 5));
        await pumpEventQueue();
        expect(audioPlayerService.currentSong?.id, 'song1');
        expect(audioPlayerService.currentPosition, const Duration(seconds: 10));
        expect(audioPlayerService.totalDuration, const Duration(seconds: 180));

        gate.complete();
        await seek;
        await settle();
        expect(audioPlayerService.currentSong?.id, 'song2');
        expect(audioPlayerService.totalDuration, const Duration(minutes: 10));
        mockAudioPlayer.simulatePositionChange(const Duration(seconds: 6));
        await pumpEventQueue();
        expect(audioPlayerService.currentPosition, const Duration(seconds: 6));
        verifyNever(
          mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
        );
      });

      test('a skip meanwhile takes over', () async {
        final skip = audioPlayerService.next();
        await pumpEventQueue();
        gate.complete();
        await seek;
        await skip;
        await settle();

        expect(audioPlayerService.currentSong?.id, 'song2');
        mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 125));
        await settle();
        expect(
          audioPlayerService.currentPosition,
          const Duration(seconds: 125),
        );
        verifyNever(
          mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
        );
        verify(
          mockApi.scrobbleSubmission('song2', playedAt: anyNamed('playedAt')),
        ).called(1);
      });

      test('a new queue meanwhile takes over', () async {
        final play = audioPlayerService.playSong(
          Song(id: 'other', title: 'Other', artist: 'A', album: 'B'),
        );
        await pumpEventQueue();
        gate.complete();
        await seek;
        await play;
        await settle();

        expect(audioPlayerService.currentSong?.id, 'other');
        mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 125));
        await settle();
        expect(
          audioPlayerService.currentPosition,
          const Duration(seconds: 125),
        );
        verifyNever(
          mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
        );
        verify(
          mockApi.scrobbleSubmission('other', playedAt: anyNamed('playedAt')),
        ).called(1);
      });

      test('a jump past the next track is not followed, and updates apply '
          'again', () async {
        mockAudioPlayer.simulateTrackTransition();
        await pumpEventQueue();
        gate.complete();
        await seek;
        await settle();

        // Not an advance by one: the service stays where it was, as before
        expect(audioPlayerService.currentSong?.id, 'song1');
        mockAudioPlayer.simulatePositionChange(const Duration(seconds: 7));
        await pumpEventQueue();
        expect(audioPlayerService.currentPosition, const Duration(seconds: 7));
      });
    });

    test(
      'should NOT scrobble when skipping after seeking past the threshold',
      () async {
        mockAudioPlayer.simulateDurationChange(const Duration(seconds: 180));
        await audioPlayerService.playAlbum(threeMinuteAlbum());
        await settle();
        clearInteractions(mockApi);

        mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 10));
        // A seek from the notification or a Bluetooth device
        mockAudioPlayer.simulateSystemCommand(
          SystemCommandType.seek,
          const Duration(seconds: 150),
        );
        await settle();
        mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 155));
        await settle();

        await audioPlayerService.next();
        await settle();

        verifyNever(
          mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
        );
      },
    );

    test('should count playback after a seek toward the threshold', () async {
      mockAudioPlayer.simulateDurationChange(const Duration(seconds: 180));
      await audioPlayerService.playAlbum(threeMinuteAlbum());
      await settle();
      clearInteractions(mockApi);

      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 40));
      await audioPlayerService.seekTo(const Duration(seconds: 100));
      await settle();
      // 40 s before the seek and 50 s after it: 50% of 3 minutes
      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 149));
      await settle();
      verifyNever(
        mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')),
      );

      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 150));
      await settle();

      verify(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      ).called(1);
    });

    test(
      'should scrobble when manually skipping after meeting criteria',
      () async {
        // Create a test album with multiple songs
        final album = Album(
          id: 'album1',
          name: 'Test Album',
          artist: 'Test Artist',
          songs: [
            Song(
              id: 'song1',
              title: 'Test Song 1',
              artist: 'Test Artist',
              album: 'Test Album',
              duration: 240, // 4 minutes
            ),
            Song(
              id: 'song2',
              title: 'Test Song 2',
              artist: 'Test Artist',
              album: 'Test Album',
              duration: 180, // 3 minutes
            ),
          ],
        );

        // Set up mock duration
        mockAudioPlayer.simulateDurationChange(const Duration(seconds: 240));

        // Play the album
        await audioPlayerService.playAlbum(album);
        await settle();

        // Reset the mock to clear the nowPlaying call
        clearInteractions(mockApi);

        // Simulate playback to 50%
        mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 120));
        await settle();

        // Verify first scrobble was submitted
        verify(
          mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
        ).called(1);

        // Now manually skip to next song
        clearInteractions(mockApi);
        await audioPlayerService.next();
        await settle();

        // Verify nowPlaying was sent for the next song, but no additional scrobble
        // for song1 (already scrobbled)
        verify(
          mockApi.scrobbleNowPlaying('song2', startedAt: anyNamed('startedAt')),
        ).called(1);
        verifyNever(
          mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
        );
      },
    );

    test('should reset scrobble tracking when changing playlists', () async {
      // Create first album
      final album1 = Album(
        id: 'album1',
        name: 'Test Album 1',
        artist: 'Test Artist',
        songs: [
          Song(
            id: 'song1',
            title: 'Test Song 1',
            artist: 'Test Artist',
            album: 'Test Album 1',
            duration: 240, // 4 minutes
          ),
        ],
      );

      // Set up mock duration
      mockAudioPlayer.simulateDurationChange(const Duration(seconds: 240));

      // Play first album
      await audioPlayerService.playAlbum(album1);
      await settle();

      // Reset and simulate playback to trigger scrobble
      clearInteractions(mockApi);
      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 120));
      await settle();

      // Verify scrobble
      verify(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      ).called(1);

      // Create second album with SAME song ID (to test reset)
      final album2 = Album(
        id: 'album2',
        name: 'Test Album 2',
        artist: 'Test Artist',
        songs: [
          Song(
            id: 'song1', // Same ID as before
            title: 'Test Song 1',
            artist: 'Test Artist',
            album: 'Test Album 2',
            duration: 240,
          ),
        ],
      );

      // Play second album
      clearInteractions(mockApi);
      await audioPlayerService.playAlbum(album2);
      await settle();

      // Verify nowPlaying was sent
      verify(
        mockApi.scrobbleNowPlaying('song1', startedAt: anyNamed('startedAt')),
      ).called(1);

      // Simulate playback to 50% again
      clearInteractions(mockApi);
      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 120));
      await settle();

      // Verify scrobble was submitted AGAIN (because tracking was reset)
      verify(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      ).called(1);
    });

    test('should scrobble at 50% for songs longer than 4 minutes', () async {
      // Create a test album with a 5-minute song
      final album = Album(
        id: 'album1',
        name: 'Test Album',
        artist: 'Test Artist',
        songs: [
          Song(
            id: 'song1',
            title: 'Long Song',
            artist: 'Test Artist',
            album: 'Test Album',
            duration: 300, // 5 minutes
          ),
        ],
      );

      // Set up mock duration
      mockAudioPlayer.simulateDurationChange(const Duration(seconds: 300));

      // Play the album
      await audioPlayerService.playAlbum(album);
      await settle();

      // Reset the mock
      clearInteractions(mockApi);

      // Simulate playback to 2 minutes (which meets the 2-minute criteria)
      // Note: For songs longer than 4 minutes, the 2-minute rule applies first
      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 120));
      await settle();

      // Should scrobble at 2 minutes (whichever comes first: 50% or 2 minutes)
      verify(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      ).called(1);
    });

    test('should call scrobble methods during playback', () async {
      // This test verifies that scrobble methods are called at the right times
      // The actual error handling is done in SubsonicApi, not AudioPlayerService

      // Create a test album
      final album = Album(
        id: 'album1',
        name: 'Test Album',
        artist: 'Test Artist',
        songs: [
          Song(
            id: 'song1',
            title: 'Test Song',
            artist: 'Test Artist',
            album: 'Test Album',
            duration: 240,
          ),
        ],
      );

      // Set up mock duration
      mockAudioPlayer.simulateDurationChange(const Duration(seconds: 240));

      // Play the album
      await audioPlayerService.playAlbum(album);
      await settle();

      // Verify now playing was called when song started
      verify(
        mockApi.scrobbleNowPlaying('song1', startedAt: anyNamed('startedAt')),
      ).called(1);

      // Reset to check scrobble submission
      clearInteractions(mockApi);

      // Simulate playback to trigger scrobble
      mockAudioPlayer.simulatePlayingTo(const Duration(seconds: 120));
      await settle();

      // Verify scrobble submission was called when criteria was met
      verify(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      ).called(1);

      // Playback should continue normally
      expect(audioPlayerService.currentSong?.id, 'song1');
      expect(audioPlayerService.playbackState, PlaybackState.playing);
    });

    test('should include timestamp when scrobbling', () async {
      // Create a test album
      final album = Album(
        id: 'album1',
        name: 'Test Album',
        artist: 'Test Artist',
        songs: [
          Song(
            id: 'song1',
            title: 'Test Song',
            artist: 'Test Artist',
            album: 'Test Album',
            duration: 180,
          ),
        ],
      );

      // Set up mock duration
      mockAudioPlayer.simulateDurationChange(const Duration(seconds: 180));

      // The service's clock when playback starts
      final startedAt = mockAudioPlayer.now;

      // Play the album
      await audioPlayerService.playAlbum(album);
      await settle();

      // Reset to check scrobble submission
      clearInteractions(mockApi);

      // Trigger completion to scrobble
      mockAudioPlayer.simulateCompletion();
      await settle();

      // Verify scrobble was called and capture the timestamp
      final verification = verify(
        mockApi.scrobbleSubmission(
          'song1',
          playedAt: captureAnyNamed('playedAt'),
        ),
      );
      verification.called(1);

      // The time the song started playing
      expect(verification.captured.single, startedAt);
    });
  });
}
