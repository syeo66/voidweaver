import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/playback_persistence.dart';
import 'package:voidweaver/services/subsonic_api.dart';

void main() {
  group('PlaybackPersistenceService position saves', () {
    const interval = Duration(milliseconds: 100);
    late PlaybackPersistenceService persistence;
    late Directory directory;

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
      directory = await Directory.systemTemp.createTemp('persistence');
      persistence = PlaybackPersistenceService(
        positionSaveInterval: interval,
        directory: directory,
      );
      await persistence.initialize();
    });

    tearDown(() async {
      persistence.dispose();
      // Writes in progress could recreate it
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await directory.delete(recursive: true);
    });

    test('saves periodically while position updates keep arriving', () async {
      // Simulate continuous playback: an update every 20ms for 3 intervals.
      for (var i = 0; i < 15; i++) {
        persistence.schedulePositionSave(stateAt(0, i));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final saved = await persistence.loadPlaybackState();
      expect(saved, isNotNull);
      expect(saved!.currentPosition, greaterThan(Duration.zero));
    });

    test('writes the latest scheduled state', () async {
      persistence.schedulePositionSave(stateAt(0, 1));
      persistence.schedulePositionSave(stateAt(0, 2));
      persistence.schedulePositionSave(stateAt(0, 3));
      await Future<void>.delayed(interval * 2);

      final saved = await persistence.loadPlaybackState();
      expect(saved!.currentPosition, const Duration(seconds: 3));
    });

    test(
      'explicit save is not overwritten by a pending position save',
      () async {
        persistence.schedulePositionSave(stateAt(0, 42));
        await persistence.savePlaybackState(stateAt(1, 0));
        await Future<void>.delayed(interval * 2);

        final saved = await persistence.loadPlaybackState();
        expect(saved!.currentIndex, 1);
        expect(saved.currentPosition, Duration.zero);
      },
    );

    test('dispose writes a pending position save', () async {
      persistence.schedulePositionSave(stateAt(0, 42));
      persistence.dispose();
      await Future<void>.delayed(Duration.zero);

      final saved = await persistence.loadPlaybackState();
      expect(saved!.currentPosition, const Duration(seconds: 42));
    });

    test(
      'position saves go to a file and leave SharedPreferences alone',
      () async {
        await persistence.savePlaybackState(stateAt(0, 0));
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('playbackQueue');

        persistence.schedulePositionSave(stateAt(1, 30));
        await Future<void>.delayed(interval * 2);

        expect(prefs.getString('playbackQueue'), isNull);
        expect(prefs.getKeys(), isEmpty);
        final file = File('${directory.path}/playback_position.json');
        expect(
          jsonDecode(await file.readAsString()),
          containsPair('currentIndex', 1),
        );
        expect(File('${file.path}.tmp').existsSync(), isFalse);
      },
    );

    test('writes in a row end with the last one', () async {
      await Future.wait([
        for (var i = 0; i < 10; i++)
          persistence.savePlaybackState(stateAt(0, i)),
      ]);

      final saved = await persistence.loadPlaybackState();
      expect(saved!.currentPosition, const Duration(seconds: 9));
    });

    test('a position saved by an earlier version is restored', () async {
      final legacy = {
        'currentIndex': 1,
        'currentPositionMs': 42000,
        'isPlaying': false,
        'lastUpdated': 0,
      };
      SharedPreferences.setMockInitialValues({
        'playbackQueue': jsonEncode({
          'playlist': [for (final s in songs) s.toJson()],
        }),
        'playbackPosition': jsonEncode(legacy),
      });
      persistence = PlaybackPersistenceService(directory: directory);
      await persistence.initialize();

      final saved = await persistence.loadPlaybackState();
      expect(saved!.currentIndex, 1);
      expect(saved.currentPosition, const Duration(seconds: 42));

      // The next save moves it to the file
      await persistence.savePlaybackState(stateAt(1, 50));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('playbackPosition'), isFalse);
      final again = await persistence.loadPlaybackState();
      expect(again!.currentPosition, const Duration(seconds: 50));
    });

    test('a position file that cannot be read leaves the queue', () async {
      await persistence.savePlaybackState(stateAt(1, 30));
      await File('${directory.path}/playback_position.json')
          .writeAsString('{"currentIn');

      final saved = await persistence.loadPlaybackState();
      expect(saved!.playlist, songs);
      expect(saved.currentIndex, 0);
      expect(saved.currentPosition, Duration.zero);
    });

    test(
      'without storage for the position, the queue is still saved',
      () async {
        // A file where the directory should be
        final blocker = File('${directory.path}/blocker')..createSync();
        persistence = PlaybackPersistenceService(
          directory: Directory('${blocker.path}/sub'),
        );
        await persistence.initialize();

        await persistence.savePlaybackState(stateAt(1, 30));

        final saved = await persistence.loadPlaybackState();
        expect(saved!.playlist, songs);
        expect(saved.currentPosition, Duration.zero);
      },
    );

    test('saves the queue again once it was replaced', () async {
      await persistence.savePlaybackState(stateAt(0, 0));
      await persistence.savePlaybackState(
        PersistedPlaybackState(
          playlist: [songs[1]],
          currentIndex: 0,
          currentPosition: Duration.zero,
          isPlaying: true,
          lastUpdated: DateTime.now(),
          playlistSource: 'song',
          sourceId: 'song2',
        ),
      );

      final saved = await persistence.loadPlaybackState();
      expect(saved!.playlist, [songs[1]]);
      expect(saved.sourceId, 'song2');
    });

    test('saves the queue again once a song in it changed', () async {
      final playlist = List.of(songs);
      PersistedPlaybackState state(int seconds) => PersistedPlaybackState(
        playlist: playlist,
        currentIndex: 0,
        currentPosition: Duration(seconds: seconds),
        isPlaying: true,
        lastUpdated: DateTime.now(),
      );
      await persistence.savePlaybackState(state(0));

      // As AudioPlayerService stores ReplayGain read from the file
      playlist[1] = playlist[1].copyWith(replayGainTrackGain: -6.5);
      persistence.queueChanged();
      persistence.schedulePositionSave(state(10));
      await Future<void>.delayed(interval * 2);

      final saved = await persistence.loadPlaybackState();
      expect(saved!.playlist[1].replayGainTrackGain, -6.5);
      expect(saved.currentPosition, const Duration(seconds: 10));
    });

    test('clear discards a pending position save', () async {
      persistence.schedulePositionSave(stateAt(0, 42));
      await persistence.clearPlaybackState();
      await Future<void>.delayed(interval * 2);

      expect(await persistence.loadPlaybackState(), isNull);
    });

    test('clear removes the position file', () async {
      await persistence.savePlaybackState(stateAt(0, 42));
      await persistence.clearPlaybackState();

      expect(
        File('${directory.path}/playback_position.json').existsSync(),
        isFalse,
      );
      expect(await persistence.loadPlaybackState(), isNull);
    });

    test('clear comes after a write in progress', () async {
      final saving = persistence.savePlaybackState(stateAt(0, 42));
      await persistence.clearPlaybackState();
      await saving;

      expect(await persistence.loadPlaybackState(), isNull);
    });
  });
}
