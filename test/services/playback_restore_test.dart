import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/playback_persistence.dart';
import 'package:voidweaver/services/settings_service.dart';
import 'package:voidweaver/services/subsonic_api.dart';

import 'scrobble_test.mocks.dart';
import '../test_helpers/mock_audio_player.dart';

void main() {
  group('Playback restore', () {
    late AudioPlayerService service;
    late MockSubsonicApi mockApi;
    late MockSettingsService mockSettingsService;
    late MockAudioPlayer mockAudioPlayer;

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

    setUp(() {
      mockApi = MockSubsonicApi();
      mockSettingsService = MockSettingsService();
      mockAudioPlayer = MockAudioPlayer();

      when(mockSettingsService.replayGainMode).thenReturn(ReplayGainMode.off);
      when(mockSettingsService.replayGainPreamp).thenReturn(0.0);
      when(mockSettingsService.replayGainFallbackGain).thenReturn(0.0);
      when(mockSettingsService.replayGainPreventClipping).thenReturn(true);
      when(mockSettingsService.scrobbleMinPlayTimeMinutes).thenReturn(2.0);
      when(mockSettingsService.scrobbleThresholdPercent).thenReturn(50.0);
      when(mockSettingsService.calculateVolumeAdjustment(
        trackGain: anyNamed('trackGain'),
        albumGain: anyNamed('albumGain'),
        trackPeak: anyNamed('trackPeak'),
        albumPeak: anyNamed('albumPeak'),
      )).thenReturn(1.0);
      when(mockApi.getStreamUrl(any)).thenReturn('https://example.com/stream');
    });

    tearDown(() {
      service.dispose();
      mockAudioPlayer.dispose();
    });

    Future<void> restoreAt(Duration position) async {
      final saved = PersistedPlaybackState(
        playlist: [song],
        currentIndex: 0,
        currentPosition: position,
        isPlaying: true,
        lastUpdated: DateTime.now(),
      );
      SharedPreferences.setMockInitialValues(
          {'playbackState': jsonEncode(saved.toJson())});
      final persistence = PlaybackPersistenceService();
      await persistence.initialize();

      service = AudioPlayerService(mockApi, mockSettingsService,
          audioPlayer: mockAudioPlayer, persistence: persistence);
      expect(await service.restorePlaybackState(), isTrue);
      await Future.delayed(const Duration(milliseconds: 250));
    }

    test('playhead shows the restored position', () async {
      await restoreAt(const Duration(seconds: 90));

      expect(service.currentPosition, const Duration(seconds: 90));

      await service.play();
      await Future.delayed(const Duration(milliseconds: 250));
      expect(service.currentPosition, const Duration(seconds: 90));
    });

    test('restored song is scrobbled once it passes the threshold', () async {
      await restoreAt(const Duration(seconds: 60));
      clearInteractions(mockApi);

      await service.play();
      await Future.delayed(const Duration(milliseconds: 250));
      verify(mockApi.scrobbleNowPlaying('song1')).called(1);

      mockAudioPlayer.simulatePositionChange(const Duration(seconds: 150));
      await Future.delayed(const Duration(milliseconds: 250));
      verify(mockApi.scrobbleSubmission('song1',
              playedAt: anyNamed('playedAt')))
          .called(1);

      mockAudioPlayer.simulateCompletion();
      await Future.delayed(const Duration(milliseconds: 250));
      verifyNever(
          mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')));
    });

    test('restored song already past the threshold is not scrobbled again',
        () async {
      await restoreAt(const Duration(seconds: 200));
      clearInteractions(mockApi);

      await service.play();
      mockAudioPlayer.simulatePositionChange(const Duration(seconds: 250));
      await Future.delayed(const Duration(milliseconds: 250));
      mockAudioPlayer.simulateCompletion();
      await Future.delayed(const Duration(milliseconds: 250));

      verifyNever(
          mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')));
    });
  });
}
