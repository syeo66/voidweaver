import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/playback_persistence.dart';
import 'package:voidweaver/services/subsonic_api.dart';

void main() {
  group('PlaybackPersistenceService position saves', () {
    const interval = Duration(milliseconds: 100);
    late PlaybackPersistenceService persistence;

    final songs = [
      Song(id: 'song1', title: 'One', artist: 'A', album: 'B', duration: 300),
      Song(id: 'song2', title: 'Two', artist: 'A', album: 'B', duration: 300),
    ];

    PersistedPlaybackState stateAt(int index, int seconds) =>
        PersistedPlaybackState(
          playlist: songs,
          currentIndex: index,
          currentPosition: Duration(seconds: seconds),
          isPlaying: true,
          lastUpdated: DateTime.now(),
        );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      persistence = PlaybackPersistenceService(positionSaveInterval: interval);
      await persistence.initialize();
    });

    tearDown(() => persistence.dispose());

    test('saves periodically while position updates keep arriving', () async {
      // Simulate continuous playback: an update every 20ms for 3 intervals.
      for (var i = 0; i < 15; i++) {
        persistence.schedulePositionSave(stateAt(0, i));
        await Future.delayed(const Duration(milliseconds: 20));
      }

      final saved = await persistence.loadPlaybackState();
      expect(saved, isNotNull);
      expect(saved!.currentPosition, greaterThan(Duration.zero));
    });

    test('writes the latest scheduled state', () async {
      persistence.schedulePositionSave(stateAt(0, 1));
      persistence.schedulePositionSave(stateAt(0, 2));
      persistence.schedulePositionSave(stateAt(0, 3));
      await Future.delayed(interval * 2);

      final saved = await persistence.loadPlaybackState();
      expect(saved!.currentPosition, const Duration(seconds: 3));
    });

    test('explicit save is not overwritten by a pending position save',
        () async {
      persistence.schedulePositionSave(stateAt(0, 42));
      await persistence.savePlaybackState(stateAt(1, 0));
      await Future.delayed(interval * 2);

      final saved = await persistence.loadPlaybackState();
      expect(saved!.currentIndex, 1);
      expect(saved.currentPosition, Duration.zero);
    });

    test('clear discards a pending position save', () async {
      persistence.schedulePositionSave(stateAt(0, 42));
      await persistence.clearPlaybackState();
      await Future.delayed(interval * 2);

      expect(await persistence.loadPlaybackState(), isNull);
    });
  });
}
