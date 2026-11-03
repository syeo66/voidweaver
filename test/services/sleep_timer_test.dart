import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/sleep_timer.dart';
import 'package:voidweaver_player/voidweaver_player.dart';

import '../test_helpers/mocks.mocks.dart';
import '../test_helpers/mock_audio_player.dart';

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
      audioPlayerService = AudioPlayerService(mockApi, mockSettingsService,
          audioPlayer: mockAudioPlayer);
    });

    tearDown(() async {
      audioPlayerService.dispose();
      await mockAudioPlayer.dispose();
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
      expect(audioPlayerService.sleepTimerRemaining!.inMinutes,
          lessThanOrEqualTo(30));
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
      expect(
          audioPlayerService.sleepTimerDuration, initialDuration + extension);
      expect(audioPlayerService.sleepTimerRemaining, isNotNull);
      expect(audioPlayerService.sleepTimerRemaining!.inMinutes,
          greaterThan(initialRemaining!.inMinutes));
    });

    test('remaining time follows the clock', () {
      var now = DateTime(2026, 1, 1, 22);
      final player = MockAudioPlayer();
      final service = AudioPlayerService(mockApi, mockSettingsService,
          audioPlayer: player, clock: () => now);
      addTearDown(() async {
        service.dispose();
        await player.dispose();
      });

      service.startSleepTimer(const Duration(minutes: 30));
      now = now.add(const Duration(minutes: 10));
      expect(service.sleepTimerRemaining, const Duration(minutes: 20));

      service.extendSleepTimer(const Duration(minutes: 5));
      expect(service.sleepTimerRemaining, const Duration(minutes: 25));

      now = now.add(const Duration(hours: 1));
      expect(service.sleepTimerRemaining, Duration.zero);
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

    test('ends the timer even if the player fails to pause', () async {
      final player = _FailingPausePlayer();
      final service =
          AudioPlayerService(mockApi, mockSettingsService, audioPlayer: player);
      addTearDown(() async {
        service.dispose();
        await player.dispose();
      });

      service.startSleepTimer(const Duration(milliseconds: 10));
      // An unhandled error from pause() would fail the test
      await Future.delayed(const Duration(milliseconds: 50));

      expect(service.isSleepTimerActive, false);
    });

    group('fade out', () {
      const fade = SleepTimer.fadeDuration;

      /// Runs [body] in fake time with a service whose clock follows it
      void inFakeTime(
          void Function(void Function(Duration) elapse,
                  AudioPlayerService service, _RecordingPlayer player)
              body) {
        fakeAsync((async) {
          final start = DateTime(2026, 1, 1, 23);
          final player = _RecordingPlayer();
          final service = AudioPlayerService(mockApi, mockSettingsService,
              audioPlayer: player, clock: () => start.add(async.elapsed));
          body(async.elapse, service, player);
          service.dispose();
          async.flushMicrotasks();
        });
      }

      test('lowers the volume over the last seconds, then pauses at full', () {
        inFakeTime((elapse, service, player) {
          service.startSleepTimer(const Duration(minutes: 10));

          elapse(const Duration(minutes: 10) - fade - Duration(seconds: 1));
          expect(player.volumes, isEmpty);

          elapse(const Duration(seconds: 1) + fade ~/ 2);
          // Half the fade left: (1/2)^3
          expect(player.volume, closeTo(0.125, 0.01));
          for (var i = 1; i < player.volumes.length; i++) {
            expect(player.volumes[i], lessThan(player.volumes[i - 1]));
          }
          expect(player.events, isNot(contains('pause')));

          elapse(fade ~/ 2);
          expect(service.isSleepTimerActive, false);
          // Silent until the pause, full volume for the next play
          expect(player.events.sublist(player.events.length - 3),
              ['volume 0.0', 'pause', 'volume 1.0']);

          elapse(const Duration(minutes: 1));
          expect(player.volume, 1.0);
        });
      });

      test('cancelling during the fade restores full volume', () {
        inFakeTime((elapse, service, player) {
          service.startSleepTimer(const Duration(minutes: 5));
          elapse(const Duration(minutes: 5) - fade ~/ 3);
          expect(player.volume, lessThan(0.5));

          service.cancelSleepTimer();
          expect(player.volume, 1.0);

          elapse(const Duration(minutes: 5));
          expect(player.volume, 1.0);
          expect(player.events, isNot(contains('pause')));
        });
      });

      test('extending during the fade restores full volume until the new end',
          () {
        inFakeTime((elapse, service, player) {
          service.startSleepTimer(const Duration(minutes: 5));
          elapse(const Duration(minutes: 5) - fade ~/ 2);
          expect(player.volume, lessThan(1.0));

          service.extendSleepTimer(const Duration(minutes: 15));
          expect(player.volume, 1.0);

          elapse(const Duration(minutes: 15) - fade ~/ 2);
          expect(player.volume, 1.0);
          elapse(fade ~/ 2);
          expect(player.volume, closeTo(0.125, 0.01));
          elapse(fade);
          expect(player.events, contains('pause'));
          expect(player.volume, 1.0);
        });
      });

      test('a timer shorter than the fade fades over all of it', () {
        inFakeTime((elapse, service, player) {
          final short = fade ~/ 2;
          service.startSleepTimer(short);
          elapse(short ~/ 2);
          expect(player.volume, closeTo(0.125, 0.01));
        });
      });

      test('a new timer during the fade restores full volume', () {
        inFakeTime((elapse, service, player) {
          service.startSleepTimer(const Duration(minutes: 1));
          elapse(const Duration(minutes: 1) - fade ~/ 2);
          expect(player.volume, lessThan(1.0));

          service.startSleepTimer(const Duration(minutes: 30));
          expect(player.volume, 1.0);
          elapse(fade);
          expect(player.volume, 1.0);
        });
      });
    });
  });
}

/// Records volume changes and pauses in the order the service makes them
class _RecordingPlayer extends MockAudioPlayer {
  final List<String> events = [];

  @override
  Future<void> setVolume(double volume) {
    final before = this.volume;
    // Recorded at the call, like pause(): the fake sets it right away
    final done = super.setVolume(volume);
    if (this.volume != before) events.add('volume ${this.volume}');
    return done;
  }

  @override
  Future<void> pause() async {
    events.add('pause');
    await super.pause();
  }
}

class _FailingPausePlayer extends MockAudioPlayer {
  @override
  Future<void> pause() async => throw PlayerException(0, 'Player released');
}
