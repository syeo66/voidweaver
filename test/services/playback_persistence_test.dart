import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/playback_persistence.dart';
import 'package:voidweaver/services/subsonic_api.dart';

import '../test_helpers/waiting.dart';

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

    /// Waits until [saved] holds for what's saved, then for the rest of
    /// that save: a read can see its queue before its position file
    Future<void> untilSaved(
      bool Function(PersistedPlaybackState? saved) saved,
    ) async {
      await pumpUntil(
        () async => saved(await persistence.loadPlaybackState()),
        reason: 'the timed save',
      );
      await savesWritten(persistence);
    }

    tearDown(() async {
      persistence.dispose();
      // Writes in progress could recreate it
      await allSavesWritten(persistence);
      await directory.delete(recursive: true);
    });

    test('saves periodically while position updates keep arriving', () async {
      // Simulate continuous playback: an update every 20ms for 3 intervals.
      for (var i = 0; i < 15; i++) {
        persistence.schedulePositionSave(stateAt(0, i));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      // A save that fired at the end is complete before the read
      await savesWritten(persistence);

      final saved = await persistence.loadPlaybackState();
      expect(saved, isNotNull);
      expect(saved!.currentPosition, greaterThan(Duration.zero));
    });

    test('writes the latest scheduled state', () async {
      persistence.schedulePositionSave(stateAt(0, 1));
      persistence.schedulePositionSave(stateAt(0, 2));
      persistence.schedulePositionSave(stateAt(0, 3));
      await untilSaved((saved) => saved != null);

      final saved = await persistence.loadPlaybackState();
      expect(saved!.currentPosition, const Duration(seconds: 3));
    });

    test(
      'explicit save is not overwritten by a pending position save',
      () async {
        persistence.schedulePositionSave(stateAt(0, 42));
        await persistence.savePlaybackState(stateAt(1, 0));
        // Past the timed save it must not make. Nothing shows a save that
        // didn't happen; too short a wait could only let the check pass.
        await Future<void>.delayed(interval * 2);

        final saved = await persistence.loadPlaybackState();
        expect(saved!.currentIndex, 1);
        expect(saved.currentPosition, Duration.zero);
      },
    );

    test('dispose writes a pending position save', () async {
      persistence.schedulePositionSave(stateAt(0, 42));
      persistence.dispose();
      // Writes the queue too (this instance never saved it)
      await savesWritten(persistence);

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
        final file = File('${directory.path}/playback_position.json');
        // The queue isn't saved again, so the file tells the save is done
        await pumpUntil(() async {
          final json = jsonDecode(await file.readAsString()) as Map;
          // Renamed into place, so never half written
          return json['currentIndex'] == 1;
        }, reason: 'the timed save');

        expect(prefs.getString('playbackQueue'), isNull);
        expect(prefs.getKeys(), isEmpty);
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
      final legacy = {'currentIndex': 1, 'currentPositionMs': 42000};
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

    test('a position saved for another queue is ignored', () async {
      await persistence.savePlaybackState(stateAt(1, 30));
      // The queue was replaced, but the process ended before the new
      // queue's first position was written
      final prefs = await SharedPreferences.getInstance();
      final queue =
          jsonDecode(prefs.getString('playbackQueue')!) as Map<String, dynamic>;
      await prefs.setString(
        'playbackQueue',
        jsonEncode({
          ...queue,
          'queueId': 'another queue',
          'playlist': [songs[0].toJson()],
        }),
      );

      final saved = await persistence.loadPlaybackState();
      expect(saved!.playlist, [songs[0]]);
      expect(saved.currentIndex, 0);
      expect(saved.currentPosition, Duration.zero);
    });

    test('a replaced queue is saved with a position of its own', () async {
      await persistence.savePlaybackState(stateAt(1, 30));
      await persistence.savePlaybackState(
        PersistedPlaybackState(
          playlist: [songs[1]],
          currentIndex: 0,
          currentPosition: const Duration(seconds: 5),
          playlistSource: 'song',
          sourceId: 'song2',
        ),
      );

      final saved = await persistence.loadPlaybackState();
      expect(saved!.playlist, [songs[1]]);
      expect(saved.currentPosition, const Duration(seconds: 5));
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
      );
      await persistence.savePlaybackState(state(0));

      // As AudioPlayerService stores ReplayGain read from the file
      playlist[1] = playlist[1].copyWith(replayGainTrackGain: -6.5);
      persistence.queueChanged();
      persistence.schedulePositionSave(state(10));
      await untilSaved(
        (saved) => saved?.currentPosition == const Duration(seconds: 10),
      );

      final saved = await persistence.loadPlaybackState();
      expect(saved!.playlist[1].replayGainTrackGain, -6.5);
      expect(saved.currentPosition, const Duration(seconds: 10));
    });

    test('a song that changed keeps the id of its queue', () async {
      final prefs = await SharedPreferences.getInstance();
      String queueId() =>
          (jsonDecode(prefs.getString('playbackQueue')!)
                  as Map<String, dynamic>)['queueId']
              as String;
      final playlist = List.of(songs);
      PersistedPlaybackState state() => PersistedPlaybackState(
        playlist: playlist,
        currentIndex: 0,
        currentPosition: Duration.zero,
      );
      await persistence.savePlaybackState(state());
      final id = queueId();

      playlist[1] = playlist[1].copyWith(replayGainTrackGain: -6.5);
      persistence.queueChanged();
      await persistence.savePlaybackState(state());
      // The queue was written again, with the song's change, under its id
      expect(prefs.getString('playbackQueue'), contains('-6.5'));
      expect(queueId(), id);

      await persistence.savePlaybackState(
        PersistedPlaybackState(
          playlist: [songs[1]],
          currentIndex: 0,
          currentPosition: Duration.zero,
        ),
      );
      expect(queueId(), isNot(id));
    });

    test('clear discards a pending position save', () async {
      persistence.schedulePositionSave(stateAt(0, 42));
      await persistence.clearPlaybackState();
      // Past the timed save it must not make (see above)
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
