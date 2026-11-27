import 'package:logging/logging.dart';

import '../models/subsonic_models.dart';
import 'playback_persistence.dart';
import 'player_worker.dart' show MoveResult;

final _log = Logger('audio_player');

/// What the queue was started from. Saved with the queue by its [name].
enum QueueSource { album, random, song }

/// Saves the queue, the index and the position, and restores them at start,
/// through [PlaybackPersistenceService] (see docs/PLAYBACK.md#restoring-playback).
/// Also keeps what the queue was started from, which is saved with it. Without
/// a persistence service nothing is saved or restored.
class PlaybackStateKeeper {
  final PlaybackStateHost _host;
  final PlaybackPersistenceService? _persistence;

  QueueSource? _source;
  String? _sourceId;

  PlaybackStateKeeper(this._host, this._persistence);

  /// What the queue was started from, null before the first queue
  QueueSource? get source => _source;

  /// Identifies where the queue came from: the album's id, the number of
  /// random songs, the song's id. Null after restoring a state that was
  /// saved without one.
  String? get sourceId => _sourceId;

  /// A new queue was started from [source].
  void startedFrom(QueueSource source, String sourceId) {
    _source = source;
    _sourceId = sourceId;
  }

  PersistedPlaybackState _state() => PersistedPlaybackState(
    playlist: _host.playlist,
    currentIndex: _host.currentIndex,
    currentPosition: _host.currentPosition,
    playlistSource: _source?.name,
    sourceId: _sourceId,
  );

  /// Saves the queue, the index and the position now.
  Future<void> save() async {
    if (_persistence == null || _host.playlist.isEmpty) return;
    await _persistence.savePlaybackState(_state());
  }

  /// Saves the position soon, throttled, see
  /// [PlaybackPersistenceService.schedulePositionSave].
  void schedulePositionSave() {
    if (_persistence == null || _host.playlist.isEmpty) return;
    _persistence.schedulePositionSave(_state());
  }

  /// Writes a scheduled position save now.
  void flushPositionSave() => _persistence?.flushPendingPositionSave();

  /// A song of the queue changed (ReplayGain read from its file): the queue
  /// is written again with the next save.
  void queueChanged() => _persistence?.queueChanged();

  /// Loads the saved queue paused, at the saved position. False if there is
  /// nothing to restore, the saved state is unusable, or the user started
  /// playback meanwhile, which the restore leaves alone. If loading fails
  /// (e.g. the server is unreachable) the restored queue stays and Play loads
  /// it again at the restored position.
  Future<bool> restore() async {
    final persistence = _persistence;
    if (persistence == null) {
      _log.fine('Persistence service not available, skipping restoration');
      return false;
    }

    try {
      final savedState = await persistence.loadPlaybackState();
      if (savedState == null || savedState.isEmpty) {
        _log.fine('No saved playback state to restore');
        return false;
      }
      if (!savedState.hasValidIndex) return false;
      // The user started playback while the saved state was loading
      if (_host.playlist.isNotEmpty) return false;

      _log.fine(
        'Attempting to restore playlist with ${savedState.playlist.length} songs',
      );

      _host.setPlaylist(savedState.playlist);
      _source = QueueSource.values.asNameMap()[savedState.playlistSource];
      _sourceId = savedState.sourceId;
      final resumeAt = savedState.currentPosition;

      final result = await _host.loadRestored(
        savedState.currentIndex,
        resumeAt,
      );
      // Playback the user started meanwhile (an album, a skip) took over
      if (result == MoveResult.superseded || result == MoveResult.stopped) {
        return false;
      }
      _log.info(
        'Successfully restored playback state: ${_host.currentSong?.title} at $resumeAt',
      );
      _host.restored(resumeAt);
      return true;
    } catch (e, stack) {
      _log.warning('Failed to restore playback state', e, stack);
      // Clear invalid saved state
      await persistence.clearPlaybackState();
    }

    return false;
  }
}

/// What [PlaybackStateKeeper] needs from the service it works for: the queue
/// and where playback is in it, and loading a restored queue.
abstract interface class PlaybackStateHost {
  /// The queue
  List<Song> get playlist;

  /// The playlist position the app shows as current
  int get currentIndex;

  /// The playback position
  Duration get currentPosition;

  /// The song the app shows as current
  Song? get currentSong;

  /// Makes [songs] the queue, without loading it
  void setPlaylist(List<Song> songs);

  /// Loads the queue at [index] and [position], paused. A load that fails
  /// stays quiet unless Play was pressed meanwhile, see `OnFailure.quiet`.
  Future<MoveResult> loadRestored(int index, Duration position);

  /// The queue is restored (loaded, or kept for Play to load again) at
  /// [position]: the app shows that position, and paused unless playing, and
  /// listeners are notified.
  void restored(Duration position);
}
