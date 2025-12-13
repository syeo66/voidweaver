import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:voidweaver/services/settings_service.dart';

import 'scrobble_test.mocks.dart';
import '../test_helpers/mock_audio_player.dart';

@GenerateMocks([SubsonicApi, SettingsService])
void main() {
  group('Scrobble Tests', () {
    late AudioPlayerService audioPlayerService;
    late MockSubsonicApi mockApi;
    late MockSettingsService mockSettingsService;
    late MockAudioPlayer mockAudioPlayer;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    setUp(() {
      mockApi = MockSubsonicApi();
      mockSettingsService = MockSettingsService();
      mockAudioPlayer = MockAudioPlayer();

      // Mock settings service methods
      when(mockSettingsService.replayGainMode).thenReturn(ReplayGainMode.off);
      when(mockSettingsService.replayGainPreamp).thenReturn(0.0);
      when(mockSettingsService.replayGainFallbackGain).thenReturn(0.0);
      when(mockSettingsService.replayGainPreventClipping).thenReturn(true);
      when(mockSettingsService.calculateVolumeAdjustment(
        trackGain: anyNamed('trackGain'),
        albumGain: anyNamed('albumGain'),
        trackPeak: anyNamed('trackPeak'),
        albumPeak: anyNamed('albumPeak'),
      )).thenReturn(1.0);

      // Mock API methods
      when(mockApi.getStreamUrl(any)).thenReturn('https://example.com/stream');

      audioPlayerService = AudioPlayerService(mockApi, mockSettingsService,
          audioPlayer: mockAudioPlayer);
    });

    tearDown(() {
      audioPlayerService.dispose();
      mockAudioPlayer.dispose();
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
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify now playing notification was sent
      verify(mockApi.scrobbleNowPlaying('song1')).called(1);
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
      await Future.delayed(const Duration(milliseconds: 100));

      // Reset the mock to clear the nowPlaying call
      clearInteractions(mockApi);

      // Simulate playback to 50% (2 minutes)
      mockAudioPlayer.simulatePositionChange(const Duration(seconds: 120));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify scrobble was submitted
      verify(mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')))
          .called(1);
    });

    test('should scrobble song when it reaches 2 minutes on a short song',
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
      await Future.delayed(const Duration(milliseconds: 100));

      // Reset the mock to clear the nowPlaying call
      clearInteractions(mockApi);

      // Simulate playback to 2 minutes (which is > 50% for a 3-minute song)
      // So the 2-minute rule should trigger first
      mockAudioPlayer.simulatePositionChange(const Duration(seconds: 120));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify scrobble was submitted
      verify(mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')))
          .called(1);
    });

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
      await Future.delayed(const Duration(milliseconds: 100));

      // Reset the mock to clear the nowPlaying call
      clearInteractions(mockApi);

      // Simulate playback to only 1 minute (less than 2 minutes and less than 50%)
      mockAudioPlayer.simulatePositionChange(const Duration(seconds: 60));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify scrobble was NOT submitted
      verifyNever(
          mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')));
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
      await Future.delayed(const Duration(milliseconds: 100));

      // Reset the mock to clear the nowPlaying call
      clearInteractions(mockApi);

      // Simulate playback past 50%
      mockAudioPlayer.simulatePositionChange(const Duration(seconds: 120));
      await Future.delayed(const Duration(milliseconds: 100));

      // Continue playback (simulate more position updates)
      mockAudioPlayer.simulatePositionChange(const Duration(seconds: 130));
      await Future.delayed(const Duration(milliseconds: 100));

      mockAudioPlayer.simulatePositionChange(const Duration(seconds: 140));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify scrobble was submitted only once
      verify(mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')))
          .called(1);
    });

    test('should scrobble when song completes', () async {
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
            duration: 180, // 3 minutes
          ),
        ],
      );

      // Set up mock duration
      mockAudioPlayer.simulateDurationChange(const Duration(seconds: 180));

      // Play the album
      await audioPlayerService.playAlbum(album);
      await Future.delayed(const Duration(milliseconds: 100));

      // Reset the mock to clear the nowPlaying call
      clearInteractions(mockApi);

      // Simulate song completion without reaching scrobble criteria during playback
      // (e.g., user skipped to end)
      mockAudioPlayer.simulatePositionChange(const Duration(seconds: 30));
      await Future.delayed(const Duration(milliseconds: 50));

      mockAudioPlayer.simulateCompletion();
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify scrobble was submitted on completion
      verify(mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')))
          .called(1);
    });

    test('should scrobble when manually skipping after meeting criteria',
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
      await Future.delayed(const Duration(milliseconds: 100));

      // Reset the mock to clear the nowPlaying call
      clearInteractions(mockApi);

      // Simulate playback to 50%
      mockAudioPlayer.simulatePositionChange(const Duration(seconds: 120));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify first scrobble was submitted
      verify(mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')))
          .called(1);

      // Now manually skip to next song
      clearInteractions(mockApi);
      await audioPlayerService.next();
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify nowPlaying was sent for the next song, but no additional scrobble
      // for song1 (already scrobbled)
      verify(mockApi.scrobbleNowPlaying('song2')).called(1);
      verifyNever(
          mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')));
    });

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
      await Future.delayed(const Duration(milliseconds: 100));

      // Reset and simulate playback to trigger scrobble
      clearInteractions(mockApi);
      mockAudioPlayer.simulatePositionChange(const Duration(seconds: 120));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify scrobble
      verify(mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')))
          .called(1);

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
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify nowPlaying was sent
      verify(mockApi.scrobbleNowPlaying('song1')).called(1);

      // Simulate playback to 50% again
      clearInteractions(mockApi);
      mockAudioPlayer.simulatePositionChange(const Duration(seconds: 120));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify scrobble was submitted AGAIN (because tracking was reset)
      verify(mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')))
          .called(1);
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
      await Future.delayed(const Duration(milliseconds: 100));

      // Reset the mock
      clearInteractions(mockApi);

      // Simulate playback to 2 minutes (which meets the 2-minute criteria)
      // Note: For songs longer than 4 minutes, the 2-minute rule applies first
      mockAudioPlayer.simulatePositionChange(const Duration(seconds: 120));
      await Future.delayed(const Duration(milliseconds: 100));

      // Should scrobble at 2 minutes (whichever comes first: 50% or 2 minutes)
      verify(mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')))
          .called(1);
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
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify now playing was called when song started
      verify(mockApi.scrobbleNowPlaying('song1')).called(1);

      // Reset to check scrobble submission
      clearInteractions(mockApi);

      // Simulate playback to trigger scrobble
      mockAudioPlayer.simulatePositionChange(const Duration(seconds: 120));
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify scrobble submission was called when criteria was met
      verify(mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')))
          .called(1);

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

      // Record the time before starting playback
      final beforePlayback = DateTime.now();

      // Play the album
      await audioPlayerService.playAlbum(album);
      await Future.delayed(const Duration(milliseconds: 100));

      // Record the time after starting playback
      final afterPlayback = DateTime.now();

      // Reset to check scrobble submission
      clearInteractions(mockApi);

      // Trigger completion to scrobble
      mockAudioPlayer.simulateCompletion();
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify scrobble was called and capture the timestamp
      final verification = verify(
          mockApi.scrobbleSubmission('song1', playedAt: captureAnyNamed('playedAt')));
      verification.called(1);

      // Verify the timestamp is reasonable (between before and after playback)
      final capturedTimestamp = verification.captured.single as DateTime;
      expect(
          capturedTimestamp.isAfter(beforePlayback) ||
              capturedTimestamp.isAtSameMomentAs(beforePlayback),
          true);
      expect(
          capturedTimestamp.isBefore(afterPlayback) ||
              capturedTimestamp.isAtSameMomentAs(afterPlayback),
          true);
    });
  });
}
