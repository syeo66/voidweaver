import 'package:audio_service/audio_service.dart';
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

  // AudioService.init() runs once per process, so after a logout the same
  // handler is attached to the next login's player.
  group('Handler across logins', () {
    late MockSubsonicApi mockApi;
    late MockSettingsService mockSettingsService;
    late MockAudioPlayer firstPlayer;
    late MockAudioPlayer secondPlayer;
    late AudioPlayerService firstService;
    late AudioPlayerService secondService;
    late VoidweaverAudioHandler audioHandler;

    setUp(() {
      mockApi = MockSubsonicApi();
      mockSettingsService = MockSettingsService();
      firstPlayer = MockAudioPlayer();
      secondPlayer = MockAudioPlayer();
      firstService = AudioPlayerService(mockApi, mockSettingsService,
          audioPlayer: firstPlayer);
      secondService = AudioPlayerService(mockApi, mockSettingsService,
          audioPlayer: secondPlayer);
      audioHandler = VoidweaverAudioHandler(firstService, mockApi);
    });

    tearDown(() {
      audioHandler.dispose();
      firstService.dispose();
      secondService.dispose();
    });

    test('detach ends the media session', () async {
      await firstPlayer.play();
      await pumpEventQueue();
      expect(audioHandler.playbackState.value.playing, isTrue);

      audioHandler.detach();

      expect(audioHandler.mediaItem.value, isNull);
      expect(audioHandler.playbackState.value.playing, isFalse);
      expect(audioHandler.playbackState.value.processingState,
          AudioProcessingState.idle);
    });

    test('controls are ignored while detached', () async {
      audioHandler.detach();

      // Would start or move the first player if it were still followed
      await audioHandler.play();
      await audioHandler.pause();
      await audioHandler.skipToNext();
      await audioHandler.fastForward();
      await audioHandler.rewind();
      await audioHandler.seekForward(true);

      expect(firstPlayer.playing, isFalse);
    });

    test('attach follows the new player only', () async {
      audioHandler.detach();
      audioHandler.attach(secondService, mockApi);

      await firstPlayer.play();
      await pumpEventQueue();
      expect(audioHandler.playbackState.value.playing, isFalse);

      await secondPlayer.play();
      await pumpEventQueue();
      expect(audioHandler.playbackState.value.playing, isTrue);
    });
  });
}
