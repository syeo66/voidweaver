import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/playback_persistence.dart';
import 'package:voidweaver/services/playback_state_keeper.dart';
import 'package:voidweaver/services/player_worker.dart' show MoveResult;
import 'package:voidweaver/services/subsonic_api.dart';

import '../test_helpers/waiting.dart';

/// A host with a queue that [PlaybackStateKeeper] saves and restores.
class _Host implements PlaybackStateHost {
  @override
  List<Song> playlist = [];
  @override
  int currentIndex = 0;
  @override
  Duration currentPosition = Duration.zero;
  @override
  Song? get currentSong => playlist.isEmpty ? null : playlist[currentIndex];

  MoveResult loadResult = MoveResult.reached;
  Object? loadError;
  final loads = <(int, Duration)>[];
  final restoredAt = <Duration>[];

  @override
  void setPlaylist(List<Song> songs) {
    playlist = songs;
  }

  @override
  Future<MoveResult> loadRestored(int index, Duration position) async {
    loads.add((index, position));
    final error = loadError;
    if (error != null) throw error;
    return loadResult;
  }

  @override
  void restored(Duration position) => restoredAt.add(position);
}

void main() {
  late Directory storage;
  late PlaybackPersistenceService persistence;
  late _Host host;
  late PlaybackStateKeeper keeper;

  Song song(String id) =>
      Song(id: id, title: 'Title $id', artist: 'Artist', album: 'Album');

  PlaybackPersistenceService newPersistence() =>
      PlaybackPersistenceService(directory: storage);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await Directory.systemTemp.createTemp('keeper_test');
    persistence = newPersistence();
    await persistence.initialize();
    host = _Host();
    keeper = PlaybackStateKeeper(host, persistence);
  });

  tearDown(() async {
    await allSavesWritten(persistence);
    await storage.delete(recursive: true);
  });

  /// What a new start would find saved
  Future<PersistedPlaybackState?> saved() async {
    final reader = newPersistence();
    await reader.initialize();
    return reader.loadPlaybackState();
  }

  group('save', () {
    test('saves the queue, the index, the position and the source', () async {
      host
        ..playlist = [song('a'), song('b')]
        ..currentIndex = 1
        ..currentPosition = const Duration(seconds: 42);
      keeper.startedFrom(QueueSource.album, 'album7');

      await keeper.save();

      final state = (await saved())!;
      expect(state.playlist.map((s) => s.id), ['a', 'b']);
      expect(state.currentIndex, 1);
      expect(state.currentPosition, const Duration(seconds: 42));
      expect(state.playlistSource, 'album');
      expect(state.sourceId, 'album7');
    });

    test('keeps what was saved when the queue is empty', () async {
      host.playlist = [song('a')];
      await keeper.save();
      await savesWritten(persistence);

      host.playlist = [];
      await keeper.save();
      await savesWritten(persistence);

      expect((await saved())!.playlist.map((s) => s.id), ['a']);
    });

    test('does nothing without a persistence service', () async {
      final keeper = PlaybackStateKeeper(host, null);
      host.playlist = [song('a')];

      await keeper.save();
      keeper
        ..schedulePositionSave()
        ..flushPositionSave()
        ..queueChanged();
      expect(await keeper.restore(), isFalse);
    });
  });

  group('restore', () {
    /// Saves a queue, then starts over as the next run would: an empty host,
    /// no source, a persistence that reads what was written
    Future<void> saveQueue() async {
      host
        ..playlist = [song('a'), song('b'), song('c')]
        ..currentIndex = 2
        ..currentPosition = const Duration(seconds: 90);
      keeper.startedFrom(QueueSource.random, '50');
      await keeper.save();
      await savesWritten(persistence);

      persistence = newPersistence();
      await persistence.initialize();
      host = _Host();
      keeper = PlaybackStateKeeper(host, persistence);
    }

    test(
      'loads the saved queue at its position and takes its source',
      () async {
        await saveQueue();

        expect(await keeper.restore(), isTrue);

        expect(host.playlist.map((s) => s.id), ['a', 'b', 'c']);
        expect(host.loads, [(2, const Duration(seconds: 90))]);
        expect(host.restoredAt, [const Duration(seconds: 90)]);
        expect(keeper.source, QueueSource.random);
        expect(keeper.sourceId, '50');
      },
    );

    test('has nothing to restore without a saved queue', () async {
      expect(await keeper.restore(), isFalse);

      expect(host.loads, isEmpty);
      expect(host.restoredAt, isEmpty);
    });

    test('leaves a queue the user started meanwhile alone', () async {
      await saveQueue();
      host.playlist = [song('new')];

      expect(await keeper.restore(), isFalse);

      expect(host.playlist.map((s) => s.id), ['new']);
      expect(host.loads, isEmpty);
      expect(keeper.source, isNull);
    });

    for (final result in [MoveResult.superseded, MoveResult.stopped]) {
      test('gives up when the load ends as $result', () async {
        await saveQueue();
        host.loadResult = result;

        expect(await keeper.restore(), isFalse);

        expect(host.restoredAt, isEmpty);
      });
    }

    test('keeps the restored queue when the load failed quietly', () async {
      await saveQueue();
      host.loadResult = MoveResult.failed;

      expect(await keeper.restore(), isTrue);

      expect(host.restoredAt, [const Duration(seconds: 90)]);
    });

    test('clears an unusable saved state and returns false', () async {
      await saveQueue();
      host.loadError = StateError('boom');

      expect(await keeper.restore(), isFalse);

      expect(await saved(), isNull);
    });
  });
}
