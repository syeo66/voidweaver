import 'dart:async';

import 'package:logging/logging.dart';
import 'package:voidweaver_player/voidweaver_player.dart';

import '../models/subsonic_models.dart' show Song;

// The service's logger, not one of its own (see lib/utils/log.dart): the
// worker does the service's work, and LOG_FINE=audio_player and the
// randomized playback test's failure dumps expect its lines under that name
final _log = Logger('audio_player');

/// Identifies an item in the player's sequence: the playlist position it
/// stands for, and the load that handed the sequence to the player (its
/// generation). Set as each source's tag, so index events map back to songs
/// even while the sequence is being changed.
class _QueueEntry {
  final int generation;
  final int index;

  const _QueueEntry(this.generation, this.index);
}

/// What happens when a move ends on a track that can't be played (and no
/// later downloaded one could take over)
enum OnFailure {
  /// The caller gets the error (starting an album, random songs, a song)
  throwToCaller,

  /// The user is told on `AudioPlayerService.playbackErrors`
  report,

  /// Neither: a restored queue waits for Play to load again
  quiet,
}

enum MoveResult { reached, failed, superseded, stopped }

/// A requested track change: the track the player should end up on, see
/// PlayerWorker._work(). Mutable: presses during a skip move its target, a
/// seek before the player call changes where it starts, and a failure turns
/// it into a search for a downloaded track to go on at.
class Move {
  Move(
    this.index,
    this.position, {
    required this.onFailure,
    required this.startsPlayback,
    required this.skip,
    required this.description,
    this.failure,
  });

  /// The playlist position it moves to, and where in that track
  int index;
  Duration position;

  final OnFailure onFailure;

  /// Whether it was asked to start playback (pause() may still hold it)
  final bool startsPlayback;

  /// A skip: presses meanwhile move its target instead of starting another
  /// one. Cleared when its target fails: what follows is error recovery.
  bool skip;

  /// Where presses during the skip have moved it: it goes on there once it
  /// has reached [index] (or [index] failed)
  int? nextIndex;

  /// For the log, and the caller's error
  final String description;

  /// Set when [index] couldn't be played: the next step looks for a
  /// downloaded track after it, or ends the move
  Object? failure;

  /// Whether the player has been told to go to [index] (a load or seek is
  /// running or done). Until then a seek just changes [position].
  bool issued = false;

  /// A seek that came after [issued], done once the target is ready
  Duration? seekAfter;

  /// stop() was called during the move, see PlayerWorker._stopEnds()
  bool stopped = false;

  /// Incremented whenever the target changes, so a step in progress notices
  int version = 0;

  final _done = Completer<MoveResult>();
  Future<MoveResult> get result => _done.future;

  void complete(MoveResult result) {
    if (!_done.isCompleted) _done.complete(result);
  }

  void fail(Object error) {
    if (!_done.isCompleted) _done.completeError(error);
  }
}

/// What [PlayerWorker] needs from the service it works for: the songs'
/// sources and data, and what a move's progress and the player's events mean
/// for the app (the current track, playback state, scrobbling, errors).
abstract interface class PlayerWorkerHost {
  /// The playlist position the app shows as current
  int get currentIndex;

  /// The player's item for the playlist position [index], tagged with [tag]
  AudioSource sourceFor(int index, Object tag);

  /// Prepares the track at [index] before the player moves there (reads its
  /// ReplayGain, so it starts at its own gain)
  Future<void> prepare(int index);

  /// The first track after [index] that's completely cached
  Future<int?> nextCachedIndex(int index);

  /// [move] has just been requested: unless it's error recovery, its track
  /// becomes current
  void moveRequested(Move move);

  /// A move's target moved to [index] (a press during a skip, or error
  /// recovery going on at a downloaded track): it becomes current, playing
  void retargeted(int index);

  /// The queue is about to be handed to the player again
  void loadingSequence();

  /// A skip leaves its target for where presses moved it, without starting
  /// it
  void passingThrough();

  /// [move] reached its target. The worker has let go of it; the host
  /// completes it and starts playback unless paused.
  void moveReached(Move move);

  /// [move] ended on its target, which couldn't be played. The worker has
  /// let go of it; the host completes or fails it, see [Move.onFailure].
  void moveFailed(Move move, Object failure);

  /// stop() ended the move (already completed as stopped) before its target
  void moveStopped();

  /// The player moved on to the next track, at playlist position [index]
  void advanced(int index);

  /// The player played the last track to its end
  void queueCompleted();

  /// The track at playlist position [index] failed while no move was in
  /// progress
  void playbackFailed(int index, PlayerException error);
}

/// Carries out every change of the player's track, sequence or position, one
/// player call at a time, and matches the player's index, end and error
/// events back to the queue. Commands only say what they want (a move, or a
/// queued operation); the worker takes them step by step. See
/// docs/PLAYBACK.md.
class PlayerWorker {
  final VoidweaverPlayer _player;
  final PlayerWorkerHost _host;

  List<Song> _playlist = [];

  // Incremented whenever the playlist or the player's sequence is replaced.
  // Sources and events from an older generation are ignored.
  int _generation = 0;
  // The playlist the player's sequence was made from (the same list, which
  // a new queue replaces), see needsLoad
  List<Song>? _loadedPlaylist;

  // Everything that changes the player's index, sequence or position runs
  // in one worker, one player call at a time (see _work()): the requested
  // track change, if any, then the queued seeks. While it runs, index
  // events and the end of the queue are left alone, and the worker catches
  // up with the player afterwards.
  Move? _move;
  final List<({Future<void> Function() run, Completer<void> done})> _ops = [];
  bool _working = false;
  Completer<void>? _workDone;
  // Completed when the requested move is replaced or retargeted, so a step
  // waiting for a ReplayGain read or the cache stops waiting, see _orChange()
  Completer<void>? _changeSignal;
  // A player error that arrived while the worker ran, handled once it's done
  // unless the worker's next player call (which loads or seeks anew)
  // supersedes it, or the move takes it as its target's failure
  PlayerException? _heldError;
  // Set while setAudioSources() runs: it throws its own load errors, and an
  // error event arriving meanwhile may be of the sequence it replaced, with
  // an index that names another item (or none) of the new one
  bool _settingSources = false;
  // The item a move took as failed (its generation and playlist index). The
  // player reports the failure on errorStream too, before or after the
  // move's call returns; a report that comes after it is dropped, so the
  // failure is handled once. Cleared by the next player call.
  ({int generation, int index})? _failedItem;
  // The index a move seeked to, until the player reports it. Until then, an
  // index event can still be from before the seek: after previous(), the
  // old track's index would look like an advance.
  int? _awaitedIndex;

  // Set when the password changed after the player's sequence was created:
  // the stream URLs of its items carry the old one, so an item that isn't
  // cached fails to load, see AudioPlayerService.credentialsChanged()
  bool _sourcesStale = false;

  late final StreamSubscription<int?> _indexSubscription;
  late final StreamSubscription<PlayerException> _errorSubscription;

  bool _disposed = false;

  PlayerWorker(this._player, this._host) {
    _indexSubscription = _player.currentIndexStream.listen(
      (_) => _followPlayer(),
    );
    _errorSubscription = _player.errorStream.listen(_onPlayerError);
  }

  /// The playlist the player plays, or is about to
  List<Song> get playlist => _playlist;

  /// The generation of the playlist, see [setPlaylist]
  int get generation => _generation;

  /// Whether a move is in progress
  bool get hasMove => _move != null;

  /// Whether the move in progress was asked to start playback once its
  /// track is ready
  bool get startsPlayback => _move?.startsPlayback ?? false;

  /// Whether the move in progress starts playback once its track is ready:
  /// pause() and stop() during it clear it, play() sets it again. Only
  /// meaningful while [hasMove].
  bool playPending = false;

  /// Changes to the player's index, sequence or position that are running or
  /// queued, see _work()
  int get pendingOps => _working ? 1 + _ops.length : 0;

  /// Whether the move in progress is a skip
  bool get skipping => _move?.skip ?? false;

  /// While a skip is in progress, the index later presses count from: where
  /// presses meanwhile have moved it, or its target. Null otherwise.
  int? get skipTarget {
    final move = _move;
    if (move == null || !move.skip) return null;
    return move.nextIndex ?? move.index;
  }

  /// A press during the skip in progress: it goes on to [index] once it has
  /// reached its target, see [skipTarget]
  void redirectSkip(int index) {
    _move!.nextIndex = index;
  }

  /// stop() was called: a move in progress doesn't start playback, and
  /// checks at its next step whether it ends, see _stopEnds()
  void stopRequested() {
    playPending = false;
    _move?.stopped = true;
  }

  /// A seek during the move in progress. Before the player has been told to
  /// go to its target, it's the position the move starts at; otherwise it's
  /// done once the target is ready.
  Future<void> seekDuringMove(Duration position) {
    final move = _move!;
    if (!move.issued) {
      // A seek queued before (one the move took back after a stop) is
      // older than this one
      move
        ..position = position
        ..seekAfter = null;
      return Future.value();
    }
    move.seekAfter = position;
    return _whenWorkDone();
  }

  /// Whether the player's items carry outdated stream URLs, see
  /// [markSourcesStale]
  bool get sourcesStale => _sourcesStale;

  /// The password changed: the stream URLs of the player's items carry the
  /// old one, so the next move loads the queue again with new URLs
  void markSourcesStale() {
    _sourcesStale = true;
  }

  /// The items of the player's current sequence, with the playlist position
  /// each stands for. None of an older generation.
  Iterable<({AudioSource source, int index})> get currentItems sync* {
    for (final source in _player.sequence) {
      final tag = source.tag;
      if (tag is! _QueueEntry || tag.generation != _generation) continue;
      yield (source: source, index: tag.index);
    }
  }

  /// Replaces the playlist. The player's sequence belongs to the one before
  /// from here on (a new generation), also if the new one never gets loaded
  /// (stop() during its load): its index events, end and errors are ignored,
  /// and its items don't get the new songs' gains.
  void setPlaylist(List<Song> songs) {
    _playlist = songs;
    ++_generation;
  }

  /// Whether going to a track needs the queue handed to the player again
  /// (rather than a seek within its sequence): it holds another playlist's
  /// sequence or none, or it's idle after stop() or an error, where a seek
  /// moves to an item without loading it.
  bool get needsLoad =>
      !identical(_loadedPlaylist, _playlist) ||
      _player.processingState == ProcessingState.idle ||
      _entryAt(_player.currentIndex) == null;

  /// Asks the worker to move to [index] of the playlist, at [position], and
  /// to start playback there if [play]. Replaces a move in progress, which
  /// completes as superseded. The host makes the track current right away
  /// (see [PlayerWorkerHost.moveRequested]), so the app shows it while it
  /// loads. With [failure], [index] has just failed: the move looks for a
  /// downloaded track after it to go on at instead.
  Future<MoveResult> requestMove(
    int index, {
    Duration position = Duration.zero,
    required bool play,
    required OnFailure onFailure,
    bool skip = false,
    String description = 'song',
    Object? failure,
  }) {
    if (_disposed) return Future.value(MoveResult.superseded);
    final move = Move(
      index,
      position,
      onFailure: onFailure,
      startsPlayback: play,
      skip: skip,
      description: description,
      failure: failure,
    );
    final previous = _move;
    _move = move;
    previous?.complete(MoveResult.superseded);
    _signalChange();
    playPending = play;
    _awaitedIndex = null;
    _host.moveRequested(move);
    _runWorker();
    return move.result;
  }

  /// Moves the target of [move] to [index], e.g. a press during a skip.
  void _retarget(Move move, int index) {
    move
      ..index = index
      ..position = Duration.zero
      ..failure = null
      ..issued = false
      ..seekAfter = null
      ..nextIndex = null
      ..version += 1;
    _signalChange();
    _awaitedIndex = null;
    _host.retargeted(index);
  }

  void _signalChange() {
    final signal = _changeSignal;
    _changeSignal = null;
    signal?.complete();
  }

  /// Waits for [work], or until the requested move changes: a new request
  /// doesn't wait for the ReplayGain read or cache lookup of the one it
  /// replaces. Not for player calls, which run to their end one at a time.
  Future<void> _orChange(Future<void> work) =>
      Future.any([work, (_changeSignal ??= Completer<void>()).future]);

  /// Runs [run] (a seek within the current track) in the worker, after the
  /// move and the operations before it.
  Future<void> queueOp(Future<void> Function() run) {
    if (_disposed) return Future.value();
    final done = Completer<void>();
    _ops.add((run: run, done: done));
    _runWorker();
    return done.future;
  }

  /// Completes once the worker has nothing left to do.
  Future<void> _whenWorkDone() {
    if (!_working) return Future.value();
    return (_workDone ??= Completer<void>()).future;
  }

  void _runWorker() {
    if (_working || _disposed) return;
    _working = true;
    unawaited(_work());
  }

  /// The worker: carries out the requested move step by step, then the
  /// queued operations, one player call at a time. Commands only change what
  /// is requested; after each await the step checks whether its move is
  /// still the one requested, with the same target, and otherwise starts
  /// over with what is requested now. Index events, the end of the queue
  /// and errors that arrive meanwhile are handled once it's done.
  Future<void> _work() async {
    try {
      while (!_disposed) {
        final move = _move;
        if (move != null) {
          try {
            await _step(move);
          } catch (e, stack) {
            // A step doesn't throw (the reads catch their own errors); if
            // one does, the move fails like any other instead of staying
            // stuck at loading
            _log.severe('Player worker step failed', e, stack);
            if (!_disposed && identical(move, _move)) {
              _finish(move, failure: e);
            }
          }
          continue;
        }
        if (_ops.isEmpty) break;
        final op = _ops.removeAt(0);
        try {
          await op.run();
          op.done.complete();
        } catch (e, stack) {
          op.done.completeError(e, stack);
        }
      }
    } finally {
      _working = false;
      final done = _workDone;
      _workDone = null;
      done?.complete();
    }
    if (_disposed) return;
    final held = _heldError;
    _heldError = null;
    if (held != null) {
      _onPlayerError(held);
    } else {
      _followPlayer();
    }
    // The end of the queue, reported while the worker ran
    if (_player.processingState == ProcessingState.completed &&
        _player.playing) {
      playerCompleted();
    }
  }

  /// One step of [move]: either the search for a downloaded track after a
  /// failure, or preparing the target (its ReplayGain) and telling the
  /// player to go there. Returns early when the move was replaced or
  /// retargeted meanwhile; the worker then calls it again for what is
  /// requested now.
  Future<void> _step(Move move) async {
    final version = move.version;
    bool changed() =>
        _disposed || !identical(move, _move) || move.version != version;

    if (_stopEnds(move)) return;
    final failure = move.failure;
    if (failure != null) {
      final pressed = move.nextIndex;
      if (pressed != null && pressed != move.index) {
        // A press during the skip moved on already: no report for this one
        _log.info('A skip to index $pressed goes on past the failed one');
        move.skip = true;
        _retarget(move, pressed);
        return;
      }
      // Not while paused (also if paused while looking): playback stops on
      // the failed track, reported
      int? found;
      if (playPending) {
        final lookup = _host.nextCachedIndex(move.index);
        await _orChange(lookup.then((index) => found = index));
      }
      // The user asked for another track, or a new queue, while looking. A
      // seek doesn't change the move, so it doesn't count. After a stop()
      // meanwhile, the failure isn't reported.
      if (changed() || _stopEnds(move)) return;
      final next = found;
      if (next != null && playPending) {
        _log.info('[offline] Continuing at cached index $next');
        _retarget(move, next);
      } else {
        if (next != null) {
          _log.info(
            '[offline] Paused meanwhile, not continuing at index $next',
          );
        }
        _finish(move, failure: failure);
      }
      return;
    }

    // Before the player moves, so the track starts at its own gain
    await _orChange(_host.prepare(move.index));
    if (changed() || _stopEnds(move)) return;

    final index = move.index;
    // After a password change the items' URLs carry the old one: a seek to
    // an item that isn't cached would fail, so the queue is loaded again
    // with new URLs (see AudioPlayerService.credentialsChanged())
    final load = needsLoad || _sourcesStale;
    // An error that arrived before this call is superseded by it: the
    // player loads or seeks anew. A track that failed while the target's
    // tags were read is what makes the player idle, so this loads.
    _heldError = null;
    _failedItem = null;
    move.issued = true;
    _awaitedIndex = load ? null : index;
    Object? error;
    try {
      if (load) {
        await _loadSequence(index, move.position);
      } else {
        await _seekToItem(index, move.position);
      }
    } on PlayerInterruptedException {
      // stop() ended the load. Not a failure: the next step ends the move
      // or loads again, see _stopEnds()
      if (!changed()) move.issued = false;
      return;
    } catch (e) {
      error = e;
    }
    if (changed()) return;
    if (error == null && _player.processingState == ProcessingState.idle) {
      if (move.stopped) {
        // stop() was called meanwhile: the next step ends the move or loads
        // again, see _stopEnds()
        move.issued = false;
        return;
      }
      final held = _heldError;
      final heldIndex = held == null ? null : _entryAt(held.index)?.index;
      if (heldIndex != null && heldIndex != index) {
        // The error of the track a skip left, on its way when the seek was
        // issued: the player is idle because of it, and a seek on an idle
        // player moves without loading. The target wasn't tried; the next
        // step loads it. (A repeat needs a new error of yet another item.)
        _log.info('Index $heldIndex failed as the skip left it');
        _heldError = null;
        move.issued = false;
        return;
      }
      // The target failed (while seeking the error came on errorStream
      // first; an error of a load's start item can come before its result,
      // while it's ignored, see _settingSources). Never loaded again
      // without a failure: a track that breaks right after it's ready would
      // be loaded again and again.
      error =
          held ?? PlayerException(0, 'Playback stopped while loading', index);
    }
    // Thrown by setAudioSources() and also reported on errorStream, or
    // taken as the target's failure here: handled once, by the move
    _heldError = null;
    if (error != null && _sourcesStale) {
      // The password changed while the call ran, so the item may have
      // failed for its old one: the next step loads the queue again with
      // new URLs. Once per change, as the load makes them current.
      _log.info('Index $index failed with outdated URLs, loading again');
      move.issued = false;
      return;
    }
    if (error != null) {
      _log.warning('Could not load index $index', error);
      _failedItem = (generation: _generation, index: index);
      // The search for a track to go on at isn't part of a skip any more:
      // presses meanwhile start a new one
      move
        ..failure = error
        ..issued = false
        ..skip = false
        ..version += 1;
      return;
    }

    // Again for a seek that came while the one before ran
    for (
      var seekAfter = move.seekAfter;
      seekAfter != null;
      seekAfter = move.seekAfter
    ) {
      move.seekAfter = null;
      try {
        await _player.seek(seekAfter);
      } catch (e) {
        _log.warning('Seek after loading failed', e);
      }
      if (changed()) return;
      if (move.stopped && _player.processingState == ProcessingState.idle) {
        // stop() was called during the seek, which it ended: the player
        // holds nothing to play. The next step ends the move or loads again
        // where the seek went, see _stopEnds()
        move
          ..issued = false
          ..position = seekAfter;
        return;
      }
    }
    final pressed = move.nextIndex;
    if (pressed != null && pressed != index) {
      // Presses during the skip moved it on: on to there, without starting
      // this track
      _host.passingThrough();
      _retarget(move, pressed);
      return;
    }
    _finish(move);
  }

  /// Ends [move]: on its target, which starts playing unless paused, or with
  /// its [failure], which goes where [Move.onFailure] says. The host does
  /// both, see [PlayerWorkerHost.moveReached] and
  /// [PlayerWorkerHost.moveFailed].
  void _finish(Move move, {Object? failure}) {
    _move = null;
    if (failure == null) {
      _host.moveReached(move);
    } else {
      _host.moveFailed(move, failure);
    }
  }

  /// Whether stop() during [move] ends it here. A skip reaches its target
  /// paused, and a move that play() came for after the stop goes on; any
  /// other move (a start, Play after an error, a restore, error recovery)
  /// ends without loading, so the stop sticks: the player stays idle,
  /// nothing is shown in the notification, and play() loads it again.
  bool _stopEnds(Move move) {
    if (!move.stopped) return false;
    move.stopped = false;
    if (playPending || move.skip) return false;
    _log.fine('Stopped during ${move.description}');
    _move = null;
    move.complete(MoveResult.stopped);
    _host.moveStopped();
    return true;
  }

  /// Hands the whole playlist to the player, starting at [startIndex] and
  /// [position]. The player plays cached tracks from the cache and streams
  /// the rest. Completes once the start track is ready; throws if it can't
  /// be loaded, or [PlayerInterruptedException] after a stop().
  Future<void> _loadSequence(int startIndex, Duration position) async {
    _host.loadingSequence();
    final generation = ++_generation;
    final sources = [
      for (var i = 0; i < _playlist.length; i++)
        _host.sourceFor(i, _QueueEntry(generation, i)),
    ];
    _loadedPlaylist = _playlist;
    _sourcesStale = false;
    _settingSources = true;
    try {
      await _player.setAudioSources(
        sources,
        initialIndex: startIndex,
        initialPosition: position,
      );
    } finally {
      _settingSources = false;
    }
  }

  /// Seeks to [position] in the item at [index]. The player's seek()
  /// completes once the item is ready or has failed; a seek that never
  /// completed would block the worker, so this also returns once the player
  /// reports an error or goes idle. The error is handled by the move, see
  /// _step().
  Future<void> _seekToItem(int index, Duration position) async {
    final failed = Completer<void>();
    void fail(Object _) {
      if (!failed.isCompleted) failed.complete();
    }

    final errors = _player.errorStream.listen(fail);
    final idle = _player.processingStateStream
        .where((state) => state == ProcessingState.idle)
        .listen(fail);
    try {
      await Future.any([_player.seek(position, index: index), failed.future]);
    } finally {
      await errors.cancel();
      await idle.cancel();
    }
  }

  /// Catches up with the player's current item. Called on index events and
  /// once the worker is done; only an advance by one, which the player makes
  /// at the end of a track, needs following.
  void _followPlayer() {
    if (_working || _disposed) return;
    final entry = _entryAt(_player.currentIndex);
    if (_awaitedIndex != null) {
      if (entry?.index == _awaitedIndex) _awaitedIndex = null;
      return;
    }
    if (entry == null || entry.index != _host.currentIndex + 1) return;

    _log.fine('Player advanced to index ${entry.index}');
    _host.advanced(entry.index);
  }

  /// The playlist entry behind the player's item at [sequenceIndex], if it
  /// belongs to the current sequence.
  _QueueEntry? _entryAt(int? sequenceIndex) {
    final tag = _tagAt(sequenceIndex);
    return tag?.generation == _generation ? tag : null;
  }

  /// The tag of the player's item at [sequenceIndex], of whichever sequence.
  _QueueEntry? _tagAt(int? sequenceIndex) {
    final sequence = _player.sequence;
    if (sequenceIndex == null || sequenceIndex >= sequence.length) return null;
    final tag = sequence[sequenceIndex].tag;
    return tag is _QueueEntry ? tag : null;
  }

  /// The player reached the end of its sequence (`completed` while
  /// playing). Handled once the worker isn't changing the player (checked
  /// again after it, see _work()), and only if the player is on the host's
  /// current track. Otherwise the end belongs to a track the queue has moved
  /// away from: a skip's target (still reading its ReplayGain before the
  /// seek) or a new queue's start track would be taken as played to its
  /// end, and scrobbled.
  ///
  /// The finished track isn't credited with the rest after its last position
  /// update then: a skip already scrobbled it if it passed the threshold,
  /// and a new queue's load means the user left it.
  void playerCompleted() {
    if (_working || _disposed) return;
    final entry = _entryAt(_player.currentIndex);
    if (entry == null || entry.index != _host.currentIndex) {
      _log.fine('Ignoring the end of a track the queue moved away from');
      return;
    }
    _host.queueCompleted();
  }

  /// A track failed to load or play (the player is idle now). While the
  /// worker runs, the error is held for it, see _work() and _step().
  void _onPlayerError(PlayerException error) {
    // setAudioSources() throws its errors, see _loadSequence()
    if (_settingSources || _disposed) return;
    // An item of a sequence a load is replacing (it's still reading the
    // start track's ReplayGain): the load replaces it anyway. Otherwise the
    // error would stop the new queue's start track, which never played. An
    // error without an item in the sequence (no index, or past its end) is
    // taken as the current sequence's.
    final generation = _tagAt(error.index)?.generation ?? _generation;
    if (generation != _generation) {
      _log.fine('Ignoring an error of a replaced queue', error);
      return;
    }
    final failed = _failedItem;
    if (failed != null &&
        failed.generation == generation &&
        failed.index == (_entryAt(error.index)?.index ?? _host.currentIndex)) {
      _log.fine('Ignoring the report of a failure the move handled', error);
      return;
    }
    if (_working) {
      // The move takes it as its target's failure, or its next player call
      // supersedes it (the error of a track a skip left, or of one that
      // failed while the target's tags were read), or it's handled once the
      // worker is done. setAudioSources() throws its own errors as well;
      // the move clears the copy held here, so it's handled once.
      _heldError = error;
      return;
    }

    final failedIndex = _entryAt(error.index)?.index ?? _host.currentIndex;
    _host.playbackFailed(failedIndex, error);
  }

  /// Ends the move in progress (as superseded) and the queued operations,
  /// and stops following the player.
  void dispose() {
    _disposed = true;
    _move?.complete(MoveResult.superseded);
    _move = null;
    _signalChange();
    for (final op in _ops) {
      op.done.complete();
    }
    _ops.clear();
    unawaited(_indexSubscription.cancel());
    unawaited(_errorSubscription.cancel());
  }
}
