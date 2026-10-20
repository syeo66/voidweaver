import 'dart:convert';

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

    test('dispose writes a pending position save', () async {
      persistence.schedulePositionSave(stateAt(0, 42));
      persistence.dispose();
      await Future<void>.delayed(Duration.zero);

      final saved = await persistence.loadPlaybackState();
      expect(saved!.currentPosition, const Duration(seconds: 42));
    });

    test('position saves leave the saved queue alone', () async {
      await persistence.savePlaybackState(stateAt(0, 0));
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('playbackQueue');

      persistence.schedulePositionSave(stateAt(1, 30));
      await Future.delayed(interval * 2);

      expect(prefs.getString('playbackQueue'), isNull);
      expect(jsonDecode(prefs.getString('playbackPosition')!),
          containsPair('currentIndex', 1));
    });

    test('saves the queue again once it was replaced', () async {
      await persistence.savePlaybackState(stateAt(0, 0));
      await persistence.savePlaybackState(PersistedPlaybackState(
        playlist: [songs[1]],
        currentIndex: 0,
        currentPosition: Duration.zero,
        isPlaying: true,
        lastUpdated: DateTime.now(),
        playlistSource: 'song',
        sourceId: 'song2',
      ));

      final saved = await persistence.loadPlaybackState();
      expect(saved!.playlist, [songs[1]]);
      expect(saved.sourceId, 'song2');
    });

    test('loads the state saved by older versions and replaces it', () async {
      SharedPreferences.setMockInitialValues(
          {'playbackState': jsonEncode(stateAt(1, 42).toJson())});
      final legacy = PlaybackPersistenceService();
      await legacy.initialize();

      final loaded = await legacy.loadPlaybackState();
      expect(loaded!.playlist, songs);
      expect(loaded.currentIndex, 1);
      expect(loaded.currentPosition, const Duration(seconds: 42));

      await legacy.savePlaybackState(loaded);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('playbackState'), isFalse);
      expect((await legacy.loadPlaybackState())!.currentIndex, 1);
    });

    test('clear discards a pending position save', () async {
      persistence.schedulePositionSave(stateAt(0, 42));
      await persistence.clearPlaybackState();
      await Future.delayed(interval * 2);

      expect(await persistence.loadPlaybackState(), isNull);
    });
  });
}
