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
    const MethodChannel audioFocusChannel = MethodChannel('voidweaver/audio_focus');
    final List<MethodCall> methodCalls = [];

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      
      // Mock the method channel responses
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioFocusChannel, (MethodCall methodCall) async {
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

    test('should handle play command without immediate audio focus conflicts', () async {
      // Simulate a play command from Bluetooth controls
      await audioHandler.play();
      
      // Wait for the delayed audio focus request
      await Future.delayed(const Duration(milliseconds: 150));
      
      // Verify that audio focus was requested (with delay)
      expect(methodCalls.where((call) => call.method == 'requestAudioFocus').length, 1);
      
      // The test passes if no exceptions were thrown during the play operation
    });

    test('should track audio focus state to avoid duplicate requests', () async {
      // First play command
      await audioHandler.play();
      await Future.delayed(const Duration(milliseconds: 150));
      
      // Second play command (should not request focus again)
      await audioHandler.play();
      await Future.delayed(const Duration(milliseconds: 150));
      
      // Audio focus should only be requested once (first time)
      expect(methodCalls.where((call) => call.method == 'requestAudioFocus').length, 1);
    });

    test('should check existing audio focus before requesting', () async {
      // Mock that we already have audio focus
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioFocusChannel, (MethodCall methodCall) async {
        methodCalls.add(methodCall);
        
        switch (methodCall.method) {
          case 'hasAudioFocus':
            return true; // Simulate we already have focus
          case 'requestAudioFocus':
          case 'abandonAudioFocus':
            return true;
          default:
            return null;
        }
      });
      
      await audioHandler.play();
      await Future.delayed(const Duration(milliseconds: 150));
      
      // Should check for existing focus
      expect(methodCalls.where((call) => call.method == 'hasAudioFocus').length, 1);
      
      // Should not request new focus since we already have it
      expect(methodCalls.where((call) => call.method == 'requestAudioFocus').length, 0);
    });

    test('should abandon audio focus when stopping', () async {
      await audioHandler.stop();
      
      // Verify that audio focus was abandoned
      expect(methodCalls.where((call) => call.method == 'abandonAudioFocus').length, 1);
    });

    test('should not request audio focus during skip operations', () async {
      // Skip to next track (no playlist needed for this test)
      await audioHandler.skipToNext();
      await Future.delayed(const Duration(milliseconds: 150));
      
      // Skip operations should not request audio focus (app should already have it)
      expect(methodCalls.where((call) => call.method == 'requestAudioFocus').length, 0);
    });
  });
}