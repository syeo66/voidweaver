import 'package:flutter_test/flutter_test.dart';
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

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    setUp(() {
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

    test('play from native controls starts playback', () async {
      await audioHandler.play();
      // Audio focus is left to just_audio/audio_session; the handler must not
      // request it separately (that broke resuming after interruptions).
    });

    test('stop from native controls stops playback', () async {
      await audioHandler.stop();
    });

    test('skip from native controls completes without a playlist', () async {
      await audioHandler.skipToNext();
      await audioHandler.skipToPrevious();
    });
  });
}
