import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:voidweaver/services/settings_service.dart';
import 'package:mockito/annotations.dart';

import 'sleep_timer_test.mocks.dart';
import '../test_helpers/mock_audio_player.dart';

@GenerateMocks([SubsonicApi, SettingsService])
void main() {
  group('Sleep Timer Tests', () {
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
      audioPlayerService = AudioPlayerService(mockApi, mockSettingsService, audioPlayer: mockAudioPlayer);
    });

    tearDown(() {
      audioPlayerService.dispose();
      mockAudioPlayer.dispose();
    });

    test('should start sleep timer correctly', () {
      const duration = Duration(minutes: 30);
      
      // Initially no sleep timer should be active
      expect(audioPlayerService.isSleepTimerActive, false);
      expect(audioPlayerService.sleepTimerDuration, null);
      
      // Start sleep timer
      audioPlayerService.startSleepTimer(duration);
      
      // Verify timer is active
      expect(audioPlayerService.isSleepTimerActive, true);
      expect(audioPlayerService.sleepTimerDuration, duration);
      expect(audioPlayerService.sleepTimerRemaining, isNotNull);
      expect(audioPlayerService.sleepTimerRemaining!.inMinutes, lessThanOrEqualTo(30));
    });

    test('should cancel sleep timer correctly', () {
      const duration = Duration(minutes: 15);
      
      // Start and then cancel sleep timer
      audioPlayerService.startSleepTimer(duration);
      expect(audioPlayerService.isSleepTimerActive, true);
      
      audioPlayerService.cancelSleepTimer();
      
      // Verify timer is canceled
      expect(audioPlayerService.isSleepTimerActive, false);
      expect(audioPlayerService.sleepTimerDuration, null);
      expect(audioPlayerService.sleepTimerRemaining, null);
    });

    test('should extend sleep timer correctly', () {
      const initialDuration = Duration(minutes: 10);
      const extension = Duration(minutes: 5);
      
      // Start sleep timer
      audioPlayerService.startSleepTimer(initialDuration);
      final initialRemaining = audioPlayerService.sleepTimerRemaining;
      
      // Extend timer
      audioPlayerService.extendSleepTimer(extension);
      
      // Verify timer is extended
      expect(audioPlayerService.isSleepTimerActive, true);
      expect(audioPlayerService.sleepTimerDuration, initialDuration + extension);
      expect(audioPlayerService.sleepTimerRemaining, isNotNull);
      expect(audioPlayerService.sleepTimerRemaining!.inMinutes, 
             greaterThan(initialRemaining!.inMinutes));
    });

    test('should not extend when timer is not active', () {
      const extension = Duration(minutes: 5);
      
      // Try to extend when no timer is active
      audioPlayerService.extendSleepTimer(extension);
      
      // Verify no timer is active
      expect(audioPlayerService.isSleepTimerActive, false);
      expect(audioPlayerService.sleepTimerDuration, null);
    });

    test('should handle timer completion', () async {
      const duration = Duration(milliseconds: 100);
      
      // Start very short timer
      audioPlayerService.startSleepTimer(duration);
      expect(audioPlayerService.isSleepTimerActive, true);
      
      // Wait for timer to complete
      await Future.delayed(const Duration(milliseconds: 150));
      
      // Verify timer completed and is no longer active
      expect(audioPlayerService.isSleepTimerActive, false);
      expect(audioPlayerService.sleepTimerDuration, null);
      expect(audioPlayerService.sleepTimerRemaining, null);
    });

    test('should replace existing timer when starting new one', () {
      const firstDuration = Duration(minutes: 10);
      const secondDuration = Duration(minutes: 20);
      
      // Start first timer
      audioPlayerService.startSleepTimer(firstDuration);
      expect(audioPlayerService.sleepTimerDuration, firstDuration);
      
      // Start second timer (should replace first)
      audioPlayerService.startSleepTimer(secondDuration);
      expect(audioPlayerService.sleepTimerDuration, secondDuration);
      expect(audioPlayerService.isSleepTimerActive, true);
    });
  });
}