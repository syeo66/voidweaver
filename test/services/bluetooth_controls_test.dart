import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:mockito/annotations.dart';
import 'package:voidweaver/services/audio_handler.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:voidweaver/services/settings_service.dart';
import '../test_helpers/mock_audio_player.dart';

// Generate mocks for dependencies
@GenerateMocks([SubsonicApi, SettingsService])
import 'bluetooth_controls_test.mocks.dart';

void main() {
  group('Bluetooth Controls Tests', () {
    late VoidweaverAudioHandler audioHandler;
    late AudioPlayerService audioPlayerService;
    late MockSubsonicApi mockApi;
    late MockSettingsService mockSettingsService;
    late MockAudioPlayer mockAudioPlayer;

    // Mock method channel for audio focus
    const MethodChannel audioFocusChannel =
        MethodChannel('voidweaver/audio_focus');
    final List<MethodCall> methodCalls = [];

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();

      // Mock the method channel responses
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioFocusChannel,
              (MethodCall methodCall) async {
        methodCalls.add(methodCall);

        switch (methodCall.method) {
          case 'requestAudioFocus':
            // Simulate successful audio focus request
            return true;
          case 'abandonAudioFocus':
            // Simulate successful audio focus abandon
            return true;
          case 'hasAudioFocus':
            // Simulate no existing audio focus
            return false;
          default:
            return null;
        }
      });
    });

    setUp(() {
      methodCalls.clear();
      mockApi = MockSubsonicApi();
      mockSettingsService = MockSettingsService();
      mockAudioPlayer = MockAudioPlayer();

      // Create audio player service with mock
      audioPlayerService = AudioPlayerService(mockApi, mockSettingsService,
          audioPlayer: mockAudioPlayer);

      // Create audio handler
      audioHandler = VoidweaverAudioHandler(audioPlayerService, mockApi);
    });

    tearDown(() {
      audioHandler.dispose();
      audioPlayerService.dispose();
    });

    test(
        'play command does not request audio focus via custom channel (just_audio handles it)',
        () async {
      // just_audio (ExoPlayer) manages audio focus internally via
      // handleInterruptions: true. Requesting focus via our own listener would
      // steal AUDIOFOCUS_GAIN events from ExoPlayer, preventing auto-resume
      // after another app temporarily takes focus.
      await audioHandler.play();
      await Future.delayed(const Duration(milliseconds: 150));

      expect(
          methodCalls
              .where((call) => call.method == 'requestAudioFocus')
              .length,
          0);
    });

    test('multiple play commands do not trigger audio focus requests',
        () async {
      await audioHandler.play();
      await Future.delayed(const Duration(milliseconds: 150));
      await audioHandler.play();
      await Future.delayed(const Duration(milliseconds: 150));

      expect(
          methodCalls
              .where((call) => call.method == 'requestAudioFocus')
              .length,
          0);
    });

    test('should abandon audio focus when stopping', () async {
      await audioHandler.stop();

      // Verify that audio focus was abandoned
      expect(
          methodCalls
              .where((call) => call.method == 'abandonAudioFocus')
              .length,
          1);
    });

    test('should not request audio focus during skip operations', () async {
      // Skip to next track (no playlist needed for this test)
      await audioHandler.skipToNext();
      await Future.delayed(const Duration(milliseconds: 150));

      // Skip operations should not request audio focus (app should already have it)
      expect(
          methodCalls
              .where((call) => call.method == 'requestAudioFocus')
              .length,
          0);
    });
  });
}
