import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:voidweaver_player/voidweaver_player.dart';
import 'package:logging/logging.dart';

import 'subsonic_api.dart';
import 'settings_service.dart';
import 'replaygain_reader.dart';
import 'replaygain_resolver.dart';
import 'playback_persistence.dart';
import 'scrobble_queue.dart';
import 'audio_cache.dart';
import 'network_errors.dart';
import 'listening_tracker.dart';
import 'sleep_timer.dart';
import 'upcoming_downloads.dart';

final _log = Logger('audio_player');
final _rgLogger = Logger('replaygain');

enum PlaybackState { stopped, playing, paused, loading }

/// What the queue was started from. Saved with the queue by its [name].
enum QueueSource { album, random, song }

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
enum _OnFailure {
  /// The caller gets the error (starting an album, random songs, a song)
  throwToCaller,

  /// The user is told on [AudioPlayerService.playbackErrors]
  report,

  /// Neither: a restored queue waits for Play to load again
  quiet,
}

enum _MoveResult { reached, failed, superseded, stopped }

/// A requested track change: the track the player should end up on, see
/// AudioPlayerService._work(). Mutable: presses during a skip move its
/// target, a seek before the player call changes where it starts, and a
/// failure turns it into a search for a downloaded track to go on at.
class _Move {
  _Move(
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

  final _OnFailure onFailure;

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

  /// stop() was called during the move, see AudioPlayerService._stopEnds()
  bool stopped = false;

  /// Incremented whenever the target changes, so a step in progress notices
  int version = 0;

  final _done = Completer<_MoveResult>();
  Future<_MoveResult> get result => _done.future;

  void complete(_MoveResult result) {
    if (!_done.isCompleted) _done.complete(result);
  }

  void fail(Object error) {
    if (!_done.isCompleted) _done.completeError(error);
  }
}

/// Plays a playlist through [VoidweaverPlayer]. The whole playlist is handed
/// to the player as its sequence, so the player moves from track to track by
/// itself (gaplessly); the service follows its current index. Each item
/// carries its own ReplayGain gain. See docs/PLAYBACK.md.
class AudioPlayerService extends ChangeNotifier {
  /// Skips within this time of the previous one are ignored, as a doubled
  /// event rather than another press
  static const _skipDebounceMs = 100;

  /// How long the current track has to have played for Previous to restart
  /// it instead of going back a track
  static const _restartThreshold = Duration(seconds: 3);

  /// How often the player reports the position while the app is shown, and
  /// while it's hidden (playing with the screen off): each report wakes
  /// Dart. A second is enough for scrobbling and for saving the position.
  static const _visiblePositionInterval = Duration(milliseconds: 200);
  static const _hiddenPositionInterval = Duration(seconds: 1);

  final VoidweaverPlayer _audioPlayer;
  final SubsonicApi _api;
  final SettingsService _settingsService;
  final PlaybackPersistenceService? _persistence;
  final ScrobbleQueue _scrobbleQueue;
  final AudioCache _audioCache;
  final DateTime Function() _clock;

  PlaybackState _playbackState = PlaybackState.stopped;
  List<Song> _playlist = [];
  int _currentIndex = 0;
  // Changes several times a second, so it has its own listenable ([position])
  // instead of notifying the service's listeners
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);
  Duration _totalDuration = Duration.zero;
  Song? _currentSong;

  // Playlist source tracking for persistence
  QueueSource? _playlistSource;
  String? _sourceId;

  // Incremented whenever the playlist or the player's sequence is replaced.
  // Sources and events from an older generation are ignored.
  int _generation = 0;
  // The playlist the player's sequence was made from (the same list, which
  // a new queue replaces), see _needsLoad
  List<Song>? _loadedPlaylist;

  // Incremented whenever a new queue is requested (an album, random songs,
  // a song); a start whose songs arrive after a newer request is dropped,
  // see _startQueue()
  int _queueRequests = 0;

  // Everything that changes the player's index, sequence or position runs
  // in one worker, one player call at a time (see _work()): the requested
  // track change, if any, then the queued seeks. While it runs, index
  // events and the end of the queue are left alone, and the service catches
  // up with the player afterwards.
  _Move? _move;
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

  // Skips
  DateTime? _lastSkipTime;
  bool get _skipping => _move?.skip ?? false;

  // Whether the move in progress starts playback once its track is ready:
  // pause() and stop() during it clear it, play() sets it again
  bool _playPending = false;

  // Where play() loads the queue again when the player holds nothing to
  // play (after stop(), an error, or a restore that couldn't load)
  Duration _pendingResumePosition = Duration.zero;

  // Playback stopped on a track because the network failed while it was
  // meant to play: it's played again when the network is back, see
  // _onNetworkAvailable(). Cleared by every move, pause() and stop(). (A
  // move after the failure loads the queue, as the player is idle, which
  // takes a new generation: _onNetworkAvailable() checks that as well.)
  ({int generation, int index, DateTime failedAt})? _networkResume;

  /// How long after a network failure the network coming back still resumes
  /// playback. Media3 keeps the service in the foreground for 10 minutes
  /// after playback stops, so the app can still start playing from the
  /// background; later the user may have long moved on.
  static const networkResumeWindow = Duration(minutes: 10);

  // Set when the password changed after the player's sequence was created:
  // the stream URLs of its items carry the old one, so an item that isn't
  // cached fails to load, see credentialsChanged()
  bool _sourcesStale = false;

  // The current play of the current song: how long it has been heard, and
  // whether it has been scrobbled
  late final ListeningTracker _listening = ListeningTracker(
    _settingsService,
    clock: _clock,
  );

  late final SleepTimer _sleepTimer = SleepTimer(
    setVolume: _setVolume,
    onExpired: _onSleepTimerExpired,
    clock: _clock,
  );

  // Downloads the next tracks to the cache while playing
  late final UpcomingDownloads _downloads;

  // Reads missing ReplayGain data and calculates the gains
  late final ReplayGainResolver _replayGain = ReplayGainResolver(
    _settingsService,
    _audioCache,
    _api,
  );

  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<int?>? _currentIndexSubscription;
  StreamSubscription<PlayerException>? _errorSubscription;
  StreamSubscription<SystemCommand>? _commandSubscription;
  StreamSubscription<void>? _networkSubscription;

  final StreamController<String> _playbackErrors =
      StreamController<String>.broadcast();

  // Async work (preloads, ReplayGain reads) can finish after dispose()
  bool _disposed = false;
  Future<void>? _released;

  AudioPlayerService(
    this._api,
    this._settingsService, {
    VoidweaverPlayer? audioPlayer,
    this._persistence,
    ScrobbleQueue? scrobbleQueue,
    AudioCache? audioCache,
    @visibleForTesting Duration downloadRetryDelay = const Duration(seconds: 5),
    @visibleForTesting this._clock = DateTime.now,
  }) : _audioPlayer = audioPlayer ?? VoidweaverPlayer(),
       _scrobbleQueue = scrobbleQueue ?? ScrobbleQueue(_api),
       _audioCache = audioCache ?? AudioCache() {
    _downloads = UpcomingDownloads(
      audioCache: _audioCache,
      api: _api,
      retryDelay: downloadRetryDelay,
      onReplayGain: _storeReplayGain,
    );
    // Downloads that failed while offline start again, and scrobbles that
    // couldn't be sent go out
    _networkSubscription = _audioCache.networkAvailable.listen(
      (_) {
        _downloads.networkAvailable();
        _scrobbleQueue.networkAvailable();
        _onNetworkAvailable();
      },
      onError: (Object e) {
        _log.warning('[audio_cache] Network events failed', e);
      },
    );
    _initializePlayer();
    unawaited(_scrobbleQueue.initialize());
  }

  /// Loads and skips in progress that were asked to start playback once
  /// their track is ready (0 or 1), see [playWhenReady]
  @visibleForTesting
  int get startsInProgress => (_move?.startsPlayback ?? false) ? 1 : 0;

  /// Changes to the player's index, sequence or position that are running or
  /// queued, see _work(). While there are any, index events and the end of
  /// the queue wait until they're done.
  @visibleForTesting
  int get pendingPlayerOps => _working ? 1 + _ops.length : 0;

  /// Whether the next play() or skip loads the queue again (after stop() or
  /// an error) instead of seeking
  @visibleForTesting
  bool get needsSourceReload => _playlist.isNotEmpty && _needsLoad;

  /// Whether a skip is being carried out. Nothing in the UI depends on it:
  /// the skip buttons stay enabled, a press moves the skip's target, see
  /// _skip().
  @visibleForTesting
  bool get isSkipOperationInProgress => _skipping;

  PlaybackState get playbackState => _playbackState;
  List<Song> get playlist => _playlist;
  int get currentIndex => _currentIndex;
  Duration get currentPosition => _currentPosition;

  /// The playback position. Listen to this for the position; the service
  /// itself doesn't notify its listeners when only the position changes.
  ValueListenable<Duration> get position => _position;
  Duration get _currentPosition => _position.value;
  set _currentPosition(Duration value) {
    if (!_disposed) _position.value = value;
  }

  Duration get totalDuration => _totalDuration;
  Song? get currentSong => _currentSong;
  bool get hasNext => _currentIndex < _playlist.length - 1;
  bool get hasPrevious => _currentIndex > 0;

  /// Whether playback runs, or starts once the track is ready. While
  /// [playbackState] is loading, this tells a pause (during a load or
  /// buffering) from playback that's about to continue.
  bool get playWhenReady => _move != null ? _playPending : _audioPlayer.playing;

  /// Messages for the user about playback that stopped because a track
  /// couldn't be played and no later one was downloaded: after Play, a skip,
  /// or a track failing while it plays. Starting an album, random songs or a
  /// song reports its failure by throwing instead, for the caller to show.
  Stream<String> get playbackErrors => _playbackErrors.stream;

  /// Called when the app is shown or hidden, see [AppState.setVisible]. While
  /// it's hidden the player reports the position less often.
  void setVisible(bool visible) {
    if (_disposed) return;
    unawaited(
      _audioPlayer
          .setPositionUpdateInterval(
            visible ? _visiblePositionInterval : _hiddenPositionInterval,
          )
          .catchError((Object e) {
            _log.warning('Could not set the position update interval', e);
          }),
    );
  }

  bool get isSleepTimerActive => _sleepTimer.isActive;
  Duration? get sleepTimerDuration => _sleepTimer.duration;
  Duration? get sleepTimerRemaining => _sleepTimer.remaining;

  void _initializePlayer() {
    _positionSubscription = _audioPlayer.positionStream.listen((position) {
      _currentPosition = position;
      _listening.onPosition(
        position,
        playing: _playbackState == PlaybackState.playing,
      );
      if (_playbackState == PlaybackState.playing) {
        _scrobbleCurrentSongIfEligible();
        _schedulePositionSave();
      }
    });

    _durationSubscription = _audioPlayer.durationStream.listen((duration) {
      _totalDuration = duration ?? Duration.zero;
      notifyListeners();
    });

    _currentIndexSubscription = _audioPlayer.currentIndexStream.listen(
      (_) => _followPlayer(),
    );

    _errorSubscription = _audioPlayer.errorStream.listen(_onPlayerError);

    _commandSubscription = _audioPlayer.commandStream.listen(_onSystemCommand);

    _playerStateSubscription = _audioPlayer.playerStateStream.listen((state) {
      _log.fine('State changed to: $state');
      switch (state.processingState) {
        case ProcessingState.completed:
          // Not again after _onQueueCompleted() paused the player
          if (state.playing) _onPlayerCompleted();
          return;
        case ProcessingState.idle:
          if (!state.playing) _playbackState = PlaybackState.stopped;
          break;
        case ProcessingState.loading:
        case ProcessingState.buffering:
          _playbackState = PlaybackState.loading;
          break;
        case ProcessingState.ready:
          // The player keeps `playing` true while buffering and on
          // completion, so ready + not playing is always a pause
          _playbackState = state.playing
              ? PlaybackState.playing
              : PlaybackState.paused;
          break;
      }
      notifyListeners();
    });
  }

  /// A command from the notification, lock screen, Bluetooth or media
  /// buttons. They go through the same methods as the app's own controls.
  void _onSystemCommand(SystemCommand command) {
    _log.fine('[native_controls] $command');
    final Future<void> result = switch (command.type) {
      SystemCommandType.play => play(),
      SystemCommandType.pause => pause(),
      SystemCommandType.stop => stop(),
      SystemCommandType.next => next(),
      SystemCommandType.previous => previous(),
      SystemCommandType.seek => seekTo(command.position ?? Duration.zero),
    };
    unawaited(
      result.catchError((Object e) {
        _log.warning('[native_controls] $command failed', e);
      }),
    );
  }

  // Persistence methods
  Future<bool> restorePlaybackState() async {
    if (_persistence == null) {
      _log.fine('Persistence service not available, skipping restoration');
      return false;
    }

    try {
      final savedState = await _persistence.loadPlaybackState();
      if (savedState == null || savedState.isEmpty) {
        _log.fine('No saved playback state to restore');
        return false;
      }
      if (!savedState.hasValidIndex) return false;
      // The user started playback while the saved state was loading
      if (_playlist.isNotEmpty) return false;

      _log.fine(
        'Attempting to restore playlist with ${savedState.playlist.length} songs',
      );

      _setPlaylist(savedState.playlist);
      _playlistSource = QueueSource.values
          .asNameMap()[savedState.playlistSource];
      _sourceId = savedState.sourceId;
      final resumeAt = savedState.currentPosition;

      // Load the queue but don't auto-play. If that fails (e.g. the server
      // is unreachable) keep the restored queue: play() loads it again at
      // the restored position.
      final result = await _requestMove(
        savedState.currentIndex,
        position: resumeAt,
        play: false,
        onFailure: _OnFailure.quiet,
        description: 'restored song',
      );
      // Playback the user started meanwhile (an album, a skip) took over
      if (result == _MoveResult.superseded || result == _MoveResult.stopped) {
        return false;
      }
      _currentPosition = resumeAt;
      // User must manually resume, unless Play was pressed while it loaded
      if (!_audioPlayer.playing) _playbackState = PlaybackState.paused;

      _log.info(
        'Successfully restored playback state: ${_currentSong?.title} at $resumeAt',
      );
      notifyListeners();
      return true;
    } catch (e, stack) {
      _log.warning('Failed to restore playback state', e, stack);
      // Clear invalid saved state
      await _persistence.clearPlaybackState();
    }

    return false;
  }

  /// Plays if the app was started for a Play media button while it wasn't
  /// running, see [VoidweaverPlayer.takeResumeRequest]. Call after
  /// [restorePlaybackState].
  Future<void> resumeIfRequested() async {
    if (await _audioPlayer.takeResumeRequest()) {
      _log.info('Resuming playback for a media button');
      await play();
    }
  }

  PersistedPlaybackState _persistedState() => PersistedPlaybackState(
    playlist: _playlist,
    currentIndex: _currentIndex,
    currentPosition: _currentPosition,
    isPlaying: _playbackState == PlaybackState.playing,
    lastUpdated: _clock(),
    playlistSource: _playlistSource?.name,
    sourceId: _sourceId,
  );

  Future<void> _saveCurrentState() async {
    if (_persistence == null || _playlist.isEmpty) return;
    await _persistence.savePlaybackState(_persistedState());
  }

  void _schedulePositionSave() {
    if (_persistence == null || _playlist.isEmpty) return;
    _persistence.schedulePositionSave(_persistedState());
  }

  Future<void> playAlbum(Album album) =>
      _startQueue('album ${album.name}', QueueSource.album, album.id, () async {
        var songs = album.songs;
        if (songs.isEmpty) {
          _log.fine(
            'Album ${album.name} has no songs, trying to fetch from API...',
          );
          songs = (await _api.getAlbum(album.id)).songs;
        }
        if (songs.isEmpty) {
          throw const UserFacingException('Album has no songs');
        }
        return songs;
      });

  Future<void> playRandomSongs([int count = 50]) => _startQueue(
    'random songs',
    QueueSource.random,
    count.toString(),
    () async {
      final songs = await _api.getRandomSongs(count);
      if (songs.isEmpty) {
        throw const UserFacingException('No random songs available');
      }
      return songs;
    },
  );

  /// Replaces the queue with the songs [fetch] returns and plays it from the
  /// start. Shows loading meanwhile. If [fetch] fails (e.g. offline), the
  /// current queue keeps playing, or stays paused, as if nothing happened.
  /// Only the last of several starts in a row takes over.
  Future<void> _startQueue(
    String description,
    QueueSource source,
    String sourceId,
    Future<List<Song>> Function() fetch,
  ) async {
    final request = ++_queueRequests;
    final previousState = _playbackState;
    _playbackState = PlaybackState.loading;
    notifyListeners();

    final List<Song> songs;
    try {
      songs = await fetch();
    } catch (e) {
      _log.warning('Could not start $description', e);
      // Unless the player reported a state meanwhile (a pause, the next
      // track), which is the current one
      if (request == _queueRequests &&
          _playbackState == PlaybackState.loading) {
        _playbackState = previousState;
        notifyListeners();
      }
      rethrow;
    }
    // Another album or random was started meanwhile
    if (request != _queueRequests) return;

    _log.info('Playing $description: ${songs.length} songs');
    _setPlaylist(List.of(songs));
    _playlistSource = source;
    _sourceId = sourceId;
    await _startPlaylist(description);
  }

  Future<void> playSong(Song song) async {
    // An album or random still being fetched doesn't replace this one
    ++_queueRequests;
    _setPlaylist([song]);
    _playlistSource = QueueSource.song;
    _sourceId = song.id;
    await _startPlaylist('song');
  }

  /// Replaces the playlist. The player's sequence belongs to the one before
  /// from here on (a new generation), also if the new one never gets loaded
  /// (stop() during its load): its index events, end and errors are ignored,
  /// and its items don't get the new songs' gains.
  void _setPlaylist(List<Song> songs) {
    _playlist = songs;
    ++_generation;
  }

  /// Plays the new playlist from its start. Completes once it plays (or a
  /// later request took over); throws if it can't be played.
  Future<void> _startPlaylist(String description) async {
    await _requestMove(
      0,
      play: true,
      onFailure: _OnFailure.throwToCaller,
      description: description,
    );
  }

  /// Stops after [error] kept the current track from playing. With [report],
  /// the user is told on [playbackErrors]; without it, the caller rethrows
  /// [error] and shows it.
  void _onLoadFailed(String message, Object error, {bool report = true}) {
    _log.warning(message, error);
    final song = _currentSong;
    if (report && song != null && !_disposed) {
      _playbackErrors.add(
        NetworkErrorHelper.getErrorMessage(
          error,
          context: 'Could not play "${song.title}"',
        ),
      );
    }
    // Otherwise the player stays idle with `playing` set, which the system
    // controls show as still loading
    if (_audioPlayer.playing) {
      unawaited(_audioPlayer.pause().catchError((Object _) {}));
    }
    _playbackState = PlaybackState.stopped;
    notifyListeners();
  }

  /// Starts playback; errors show up on the player's error stream.
  void _startPlayback() {
    unawaited(
      _audioPlayer.play().catchError((Object e) {
        _log.warning('Playback error', e);
      }),
    );
  }

  /// Whether going to a track needs the queue handed to the player again
  /// (rather than a seek within its sequence): it holds another playlist's
  /// sequence or none, or it's idle after stop() or an error, where a seek
  /// moves to an item without loading it.
  bool get _needsLoad =>
      !identical(_loadedPlaylist, _playlist) ||
      _audioPlayer.processingState == ProcessingState.idle ||
      _entryAt(_audioPlayer.currentIndex) == null;

  /// Asks the worker to move to [index] of the playlist, at [position], and
  /// to start playback there if [play]. Replaces a move in progress, which
  /// completes as superseded. The track becomes current right away, so the
  /// app shows it while it loads. With [failure], [index] has just failed:
  /// the move looks for a downloaded track after it to go on at instead.
  Future<_MoveResult> _requestMove(
    int index, {
    Duration position = Duration.zero,
    required bool play,
    required _OnFailure onFailure,
    bool skip = false,
    String description = 'song',
    Object? failure,
  }) {
    if (_disposed) return Future.value(_MoveResult.superseded);
    final move = _Move(
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
    previous?.complete(_MoveResult.superseded);
    _signalChange();
    _networkResume = null;
    _playPending = play;
    _awaitedIndex = null;
    if (failure == null) {
      if (_needsLoad) _playbackState = PlaybackState.loading;
      _setCurrentTrack(index, position: position, playing: play);
    }
    _runWorker();
    return move.result;
  }

  /// Moves the target of [move] to [index], e.g. a press during a skip.
  void _retarget(_Move move, int index) {
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
    _setCurrentTrack(index, playing: true);
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
  Future<void> _queueOp(Future<void> Function() run) {
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
    if (_audioPlayer.processingState == ProcessingState.completed &&
        _audioPlayer.playing) {
      _onPlayerCompleted();
    }
  }

  /// One step of [move]: either the search for a downloaded track after a
  /// failure, or reading the target's ReplayGain and telling the player to
  /// go there. Returns early when the move was replaced or retargeted
  /// meanwhile; the worker then calls it again for what is requested now.
  Future<void> _step(_Move move) async {
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
      if (_playPending) {
        final lookup = _nextCachedIndex(move.index);
        await _orChange(lookup.then((index) => found = index));
      }
      // The user asked for another track, or a new queue, while looking. A
      // seek doesn't change the move, so it doesn't count. After a stop()
      // meanwhile, the failure isn't reported.
      if (changed() || _stopEnds(move)) return;
      final next = found;
      if (next != null && _playPending) {
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
    await _orChange(_loadReplayGain(move.index));
    if (changed() || _stopEnds(move)) return;

    final index = move.index;
    // After a password change the items' URLs carry the old one: a seek to
    // an item that isn't cached would fail, so the queue is loaded again
    // with new URLs (see credentialsChanged())
    final load = _needsLoad || _sourcesStale;
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
    if (error == null && _audioPlayer.processingState == ProcessingState.idle) {
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
        await _audioPlayer.seek(seekAfter);
      } catch (e) {
        _log.warning('Seek after loading failed', e);
      }
      if (changed()) return;
      if (move.stopped &&
          _audioPlayer.processingState == ProcessingState.idle) {
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
      _scrobbleCurrentSongIfEligible();
      _retarget(move, pressed);
      return;
    }
    _finish(move);
  }

  /// Ends [move]: on its target, which starts playing unless paused, or with
  /// its [failure], which goes where [_Move.onFailure] says.
  void _finish(_Move move, {Object? failure}) {
    _move = null;
    if (failure == null) {
      _pendingResumePosition = Duration.zero;
      move.complete(_MoveResult.reached);
      _startUnlessPaused();
      return;
    }
    if (move.index != _currentIndex) {
      _setCurrentTrack(move.index, playing: false);
    }
    switch (move.onFailure) {
      case _OnFailure.throwToCaller:
        _pendingResumePosition = Duration.zero;
        _onLoadFailed(
          'Failed to play ${move.description}',
          failure,
          report: false,
        );
        move.fail(failure);
      case _OnFailure.report:
        // After a network failure, play() goes on where the track broke off,
        // and so does the network coming back if it was meant to play
        final network = _isNetworkFailure(failure);
        _pendingResumePosition = network ? move.position : Duration.zero;
        if (network && _playPending) {
          _networkResume = (
            generation: _generation,
            index: move.index,
            failedAt: _clock(),
          );
        }
        _onLoadFailed('Failed to play ${move.description}', failure);
        move.complete(_MoveResult.failed);
      case _OnFailure.quiet:
        // play() loads it again where it was meant to start
        _pendingResumePosition = move.position;
        if (_playPending) {
          // Play was pressed while it loaded: the user is told, as after
          // any other Play
          _onLoadFailed('Failed to play ${move.description}', failure);
        } else {
          _log.warning(
            'Could not load ${move.description}, will retry on play',
            failure,
          );
        }
        move.complete(_MoveResult.failed);
    }
  }

  /// Whether stop() during [move] ends it here. A skip reaches its target
  /// paused, and a move that play() came for after the stop goes on; any
  /// other move (a start, Play after an error, a restore, error recovery)
  /// ends without loading, so the stop sticks: the player stays idle,
  /// nothing is shown in the notification, and play() loads it again.
  bool _stopEnds(_Move move) {
    if (!move.stopped) return false;
    move.stopped = false;
    if (_playPending || move.skip) return false;
    _log.fine('Stopped during ${move.description}');
    _move = null;
    move.complete(_MoveResult.stopped);
    _listening.clearStart();
    if (_audioPlayer.processingState == ProcessingState.idle) {
      _playbackState = PlaybackState.stopped;
    }
    notifyListeners();
    return true;
  }

  AudioSource _sourceFor(int generation, int index) {
    final song = _playlist[index];
    final tag = _QueueEntry(generation, index);
    final gain = _gainFor(song);
    final artUri = song.coverArt != null
        ? Uri.parse(_api.getCoverArtUrl(song.coverArt!))
        : null;
    return AudioSource.uri(
      Uri.parse(_api.getStreamUrl(song.id)),
      tag: tag,
      gain: gain,
      cacheKey: _audioCache.keyFor(song),
      title: song.title,
      artist: song.artist,
      album: song.album,
      artUri: artUri,
    );
  }

  /// Hands the whole playlist to the player, starting at [startIndex] and
  /// [position]. The player plays cached tracks from the cache and streams
  /// the rest. Completes once the start track is ready; throws if it can't
  /// be loaded, or [PlayerInterruptedException] after a stop().
  Future<void> _loadSequence(int startIndex, Duration position) async {
    _playbackState = PlaybackState.loading;
    notifyListeners();
    final generation = ++_generation;
    final sources = [
      for (var i = 0; i < _playlist.length; i++) _sourceFor(generation, i),
    ];
    _loadedPlaylist = _playlist;
    _sourcesStale = false;
    _settingSources = true;
    try {
      await _audioPlayer.setAudioSources(
        sources,
        initialIndex: startIndex,
        initialPosition: position,
      );
    } finally {
      _settingSources = false;
    }
  }

  /// Starts playback of the track a move has just reached, unless pause()
  /// was pressed meanwhile. Then it stays paused, and play() starts it as a
  /// new play (like a restored song).
  void _startUnlessPaused() {
    if (!_playPending) {
      _listening.clearStart();
      notifyListeners();
      return;
    }
    // A restored song that Play was pressed for while it loaded
    if (!_listening.hasStarted) _listening.markStarted();
    _startPlayback();
    _onTrackStarted();
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

    final errors = _audioPlayer.errorStream.listen(fail);
    final idle = _audioPlayer.processingStateStream
        .where((state) => state == ProcessingState.idle)
        .listen(fail);
    try {
      await Future.any([
        _audioPlayer.seek(position, index: index),
        failed.future,
      ]);
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
    final entry = _entryAt(_audioPlayer.currentIndex);
    if (_awaitedIndex != null) {
      if (entry?.index == _awaitedIndex) _awaitedIndex = null;
      return;
    }
    if (entry == null || entry.index != _currentIndex + 1) return;

    _log.fine('Player advanced to index ${entry.index}');
    _listening.listenedToEnd(_currentSongDuration);
    _scrobbleCurrentSongIfEligible();
    _setCurrentTrack(entry.index, playing: true);
    unawaited(_loadReplayGain(entry.index));
    _onTrackStarted();
  }

  /// The playlist entry behind the player's item at [sequenceIndex], if it
  /// belongs to the current sequence.
  _QueueEntry? _entryAt(int? sequenceIndex) {
    final tag = _tagAt(sequenceIndex);
    return tag?.generation == _generation ? tag : null;
  }

  /// The tag of the player's item at [sequenceIndex], of whichever sequence.
  _QueueEntry? _tagAt(int? sequenceIndex) {
    final sequence = _audioPlayer.sequence;
    if (sequenceIndex == null || sequenceIndex >= sequence.length) return null;
    final tag = sequence[sequenceIndex].tag;
    return tag is _QueueEntry ? tag : null;
  }

  void _setCurrentTrack(
    int index, {
    Duration position = Duration.zero,
    required bool playing,
  }) {
    _currentIndex = index;
    _currentSong = _playlist[index];
    _currentPosition = position;
    // A restored song starts once it's resumed, see play()
    _listening.startPlay(
      position,
      Duration(seconds: _currentSong!.duration ?? 0),
      playing: playing,
    );
    notifyListeners();
  }

  /// Bookkeeping once a track is playing.
  void _onTrackStarted() {
    unawaited(_scrobbleQueue.queueNowPlaying(_currentSong!.id));
    unawaited(_preloadUpcomingSongs());
    unawaited(_saveCurrentState());
    notifyListeners();
  }

  /// The player reached the end of its sequence. Handled once the worker
  /// isn't changing the player (checked again after it, see _work()), and
  /// only if the player is on the service's current track. Otherwise the end
  /// belongs to a track the service has moved away from: a skip's target
  /// (still reading its ReplayGain before the seek) or a new queue's start
  /// track would be taken as played to its end, and scrobbled.
  ///
  /// The finished track isn't credited with the rest after its last position
  /// update then (no listenedToEnd()): a skip already scrobbled it if it
  /// passed the threshold, and a new queue's load means the user left it.
  void _onPlayerCompleted() {
    if (_working || _disposed) return;
    final entry = _entryAt(_audioPlayer.currentIndex);
    if (entry == null || entry.index != _currentIndex) {
      _log.fine('Ignoring the end of a track the queue moved away from');
      return;
    }
    _onQueueCompleted();
  }

  /// The last track played to its end. The player stays completed with
  /// `playing` set, which the system controls show as playing, and play()
  /// does nothing in that state. So pause at the start of the last track: Play
  /// replays it, as a new play (like a restored song, see play()).
  void _onQueueCompleted() {
    _log.info('End of playlist reached');
    _listening.listenedToEnd(_currentSongDuration);
    _scrobbleCurrentSongIfEligible();
    _setCurrentTrack(_currentIndex, playing: false);
    _playbackState = PlaybackState.paused;
    notifyListeners();
    unawaited(
      _queueOp(() async {
        await _audioPlayer.pause();
        await _audioPlayer.seek(Duration.zero);
      }).catchError((Object e) {
        _log.warning('Could not rewind after the last track', e);
      }),
    );
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
        failed.index == (_entryAt(error.index)?.index ?? _currentIndex)) {
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

    final failedIndex = _entryAt(error.index)?.index ?? _currentIndex;
    _log.warning('Playback error at index $failedIndex', error);
    _pendingResumePosition = Duration.zero;
    if (_sourcesStale && playWhenReady) {
      // Most likely the old password in the item's URL: load the queue
      // again, with new URLs, where it failed. If that fails too, it's
      // handled like any load error.
      final position = failedIndex == _currentIndex
          ? _currentPosition
          : Duration.zero;
      _log.info(
        'Loading the queue again at index $failedIndex '
        'with the new credentials',
      );
      unawaited(
        _requestMove(
          failedIndex,
          position: position,
          play: true,
          onFailure: _OnFailure.report,
        ),
      );
      return;
    }
    // Continues at the next downloaded track if it was playing; stops on
    // the failed one, reported, if it was paused or nothing later is
    // downloaded. play() tries it again then, where it broke off if the
    // network failed (see _finish()).
    unawaited(
      _requestMove(
        failedIndex,
        position: failedIndex == _currentIndex
            ? _currentPosition
            : Duration.zero,
        play: playWhenReady,
        onFailure: _OnFailure.report,
        failure: error,
      ),
    );
  }

  /// Whether [failure] is the player failing to reach the server (the
  /// connection failed, broke off or timed out), as opposed to the server
  /// answering with an error (Media3 code 2004), or with a document instead
  /// of audio (2000, see `LoadErrorPolicy`), which it would answer again.
  static bool _isNetworkFailure(Object failure) =>
      failure is PlayerException &&
      (failure.code == 2001 || // ERROR_CODE_IO_NETWORK_CONNECTION_FAILED
          failure.code == 2002); // ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT

  /// The network is back: plays the track that stopped because the network
  /// failed (see _finish()), where it broke off, unless the user did
  /// anything with playback since, or it's been too long.
  void _onNetworkAvailable() {
    final resume = _networkResume;
    if (resume == null || _disposed) return;
    _networkResume = null;
    if (_clock().difference(resume.failedAt) > networkResumeWindow) {
      _log.info('Network is back, too long after playback stopped to resume');
      return;
    }
    if (resume.generation != _generation ||
        resume.index != _currentIndex ||
        _move != null ||
        !_needsLoad) {
      return;
    }
    _log.info('Network is back, resuming index $_currentIndex');
    unawaited(play());
  }

  /// The API's password changed (see [SubsonicApi.usePassword]). Playback
  /// goes on: the player plays cached tracks from the cache whatever their
  /// URL. Downloads of the upcoming tracks start again with the new
  /// password, and an item that fails to stream with the old one loads the
  /// queue again, see _onPlayerError().
  void credentialsChanged() {
    if (_disposed || _playlist.isEmpty) return;
    _sourcesStale = true;
    unawaited(_preloadUpcomingSongs());
  }

  /// The first track after [index] that's completely cached.
  Future<int?> _nextCachedIndex(int index) async {
    final playlist = _playlist;
    if (index + 1 >= playlist.length) return null;
    try {
      final cached = await _audioCache.firstCached(playlist.sublist(index + 1));
      if (cached == null || !identical(playlist, _playlist)) return null;
      final next = playlist.indexWhere(
        (song) => song.id == cached.id,
        index + 1,
      );
      return next < 0 ? null : next;
    } catch (e) {
      _log.warning('[audio_cache] Could not check the cache', e);
      return null;
    }
  }

  Future<void> play() async {
    _log.fine(
      'Play requested - currentSong: ${_currentSong?.title}, state: $_playbackState',
    );
    if (_playlist.isEmpty) return;

    if (_move != null) {
      // Paused during a load or skip (or stopped: a load stop() interrupted
      // loads again): it starts playback once it's done
      _playPending = true;
      notifyListeners();
      return;
    }

    if (_currentSong == null || _needsLoad) {
      await _requestMove(
        _currentIndex,
        position: _pendingResumePosition,
        play: true,
        onFailure: _OnFailure.report,
      );
      return;
    }

    if (!_listening.hasStarted) {
      // First play of a song restored from a previous session
      _listening.markStarted();
      _onTrackStarted();
    }
    _startPlayback();
  }

  /// Pauses, also while a track loads or buffers: a load or skip in progress
  /// then doesn't start playback.
  Future<void> pause() async {
    _networkResume = null;
    if (_move != null && _playPending) {
      _playPending = false;
      notifyListeners();
    }
    await _audioPlayer.pause();
    // The position stream saves only while playing, so the position the
    // pause stopped at is written now, not with the next timed save
    _schedulePositionSave();
    _persistence?.flushPendingPositionSave();
  }

  /// Stops and releases the loaded track. A load in progress ends without
  /// loading; a skip in progress reaches its target paused. A play() right
  /// after the stop, while the move hasn't noticed it yet, loads and starts
  /// its target. See _stopEnds().
  Future<void> stop() async {
    _networkResume = null;
    _playPending = false;
    _move?.stopped = true;
    _pendingResumePosition = Duration.zero;
    await _audioPlayer.stop();
    _currentPosition = Duration.zero;
    _totalDuration = Duration.zero;
    _playbackState = PlaybackState.stopped;
    notifyListeners();
  }

  bool _canSkip() {
    final now = _clock();
    if (_lastSkipTime != null &&
        now.difference(_lastSkipTime!).inMilliseconds <= _skipDebounceMs) {
      return false;
    }
    _lastSkipTime = now;
    return true;
  }

  Future<void> next() => _skip('next', (from) => from + 1);

  /// Restarts the current track once it has played for a few seconds, and
  /// the first track; otherwise goes back a track.
  Future<void> previous() => _skip('previous', (from) {
    // Not during a skip: that's a press to go back further
    final restart = !_skipping && _currentPosition > _restartThreshold;
    return restart ? from : max(from - 1, 0);
  });

  /// Skips to the index [targetFrom] returns for the current one or, while a
  /// skip is in progress, for its target. A press during a skip doesn't start
  /// another one but moves the skip's target, and the skip continues there
  /// once it has reached its earlier target (without starting it). So
  /// pressing Next three times moves three tracks, however long each takes
  /// to load. Completes once the skip has reached its last target.
  ///
  /// A skip starts playback; a pause() or stop() during it holds for the rest
  /// of it, also when later presses move its target.
  Future<void> _skip(String source, int Function(int from) targetFrom) async {
    final move = _move;
    final skipping = move != null && move.skip;
    final target = targetFrom(
      skipping ? move.nextIndex ?? move.index : _currentIndex,
    );
    if (target < 0 || target >= _playlist.length) return;
    if (!_canSkip()) {
      _log.fine('[$source] Skip ignored');
      return;
    }
    if (skipping) {
      _log.fine('[$source] Skip in progress, continuing to index $target');
      move.nextIndex = target;
      return;
    }
    _scrobbleCurrentSongIfEligible();
    // Replaces a start or error recovery in progress
    await _requestMove(
      target,
      play: true,
      onFailure: _OnFailure.report,
      skip: true,
      description: 'song ($source)',
    );
  }

  /// Seeks within the current track. During a load or skip it applies to the
  /// track that one makes current: before the player has been told to go
  /// there, as the position it starts at, otherwise once it's there.
  Future<void> seekTo(Duration position) {
    final move = _move;
    if (move != null) {
      _currentPosition = position;
      // The move's end saves only if it starts playback
      _schedulePositionSave();
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
    if (_playlist.isNotEmpty && _needsLoad) {
      // Nothing loaded to seek in: play() loads it there
      _pendingResumePosition = position;
      _currentPosition = position;
      _schedulePositionSave();
      return Future.value();
    }
    final generation = _generation;
    final index = _currentIndex;
    return _queueOp(() async {
      // The queue was replaced, or the track changed, meanwhile: the position
      // was meant for the track before
      if (generation != _generation || index != _currentIndex) return;
      await _audioPlayer.seek(position);
      // A seek while paused gets no position update to save it with
      if (_playbackState != PlaybackState.playing) _currentPosition = position;
      _schedulePositionSave();
    });
  }

  /// Scrobbles the current play of the current song once it has been heard
  /// long enough, see [ListeningTracker.takeScrobble]. Queued with the time
  /// it started.
  void _scrobbleCurrentSongIfEligible() {
    final song = _currentSong;
    if (song == null) return;
    final playedAt = _listening.takeScrobble(_currentSongDuration);
    if (playedAt == null) return;
    unawaited(_scrobbleQueue.queueSubmission(song.id, playedAt: playedAt));
  }

  /// The length of the current song: as the player reports it, or from the
  /// server's metadata until it does.
  Duration get _currentSongDuration => _totalDuration > Duration.zero
      ? _totalDuration
      : Duration(seconds: _currentSong?.duration ?? 0);

  /// Makes sure the song at [index] has ReplayGain data, reading it from the
  /// file when the server didn't provide it. A gain read here is applied to
  /// the song's items in the player's sequence.
  Future<void> _loadReplayGain(int index) async {
    final playlist = _playlist;
    final data = await _replayGain.readMissing(playlist[index]);
    if (data != null) _storeReplayGain(playlist, index, data);

    if (identical(playlist, _playlist) && index == _currentIndex) {
      _logReplayGain();
    }
  }

  /// Stores ReplayGain data read from a file in the playlist entry at
  /// [index], if [playlist] is still the current one, and applies it.
  void _storeReplayGain(List<Song> playlist, int index, ReplayGainData data) {
    if (!data.hasAnyData ||
        !identical(playlist, _playlist) ||
        index >= playlist.length) {
      return;
    }
    final updated = playlist[index].copyWith(
      replayGainTrackGain: data.trackGain,
      replayGainAlbumGain: data.albumGain,
      replayGainTrackPeak: data.trackPeak,
      replayGainAlbumPeak: data.albumPeak,
    );
    playlist[index] = updated;
    // Saved with the queue's next save, so a restored queue has the gain
    // without reading the file again
    _persistence?.queueChanged();
    // Not notified: only the gain depends on it
    if (index == _currentIndex) _currentSong = updated;
    _updateGains(onlyIndex: index);
  }

  /// The linear gain [song] plays at, see [ReplayGainResolver.gainFor].
  double _gainFor(Song song) => _replayGain.gainFor(
    song,
    fromAlbum: _playlistSource == QueueSource.album,
  );

  /// Sets the gain of the items in the player's sequence (only those for
  /// playlist position [onlyIndex], if given) from their songs. Each item
  /// carries its own gain, which the player applies to that item's samples
  /// only, so a change never spills over into the neighboring tracks.
  void _updateGains({int? onlyIndex}) {
    for (final source in _audioPlayer.sequence) {
      final tag = source.tag;
      if (tag is! _QueueEntry || tag.generation != _generation) continue;
      if (onlyIndex != null && tag.index != onlyIndex) continue;
      if (tag.index >= _playlist.length) continue;
      unawaited(
        _audioPlayer.setGain(source, _gainFor(_playlist[tag.index])).catchError(
          (Object e) {
            _rgLogger.warning('Could not set gain', e);
          },
        ),
      );
    }
  }

  void _logReplayGain() {
    final song = _currentSong;
    if (song == null) return;
    _replayGain.logTrack(
      song,
      fromAlbum: _playlistSource == QueueSource.album,
      queue: _playlistSource?.name ?? 'none',
    );
  }

  /// Applies changed ReplayGain settings to every track in the queue.
  Future<void> refreshReplayGainVolume() async {
    _updateGains();
    _logReplayGain();
  }

  /// Downloads the upcoming songs to the cache, see [UpcomingDownloads].
  Future<void> _preloadUpcomingSongs() {
    final playlist = _playlist;
    return _downloads.start(
      playlist,
      _currentIndex + 1,
      isCurrent: () => !_disposed && identical(playlist, _playlist),
    );
  }

  /// Removes all cached audio.
  Future<void> clearAudioCache() => _audioCache.clear();

  /// Size of cached audio, in bytes.
  Future<int> audioCacheSize() => _audioCache.sizeInBytes();

  /// Starts the sleep timer, replacing one that's running.
  void startSleepTimer(Duration duration) {
    _sleepTimer.start(duration);
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer.cancel();
    notifyListeners();
  }

  /// Adds [extension] to a running sleep timer.
  void extendSleepTimer(Duration extension) {
    if (_sleepTimer.extend(extension)) notifyListeners();
  }

  void _setVolume(double volume) {
    if (_disposed) return;
    unawaited(
      _audioPlayer.setVolume(volume).catchError((Object e) {
        _log.warning('Could not set the volume', e);
      }),
    );
  }

  void _onSleepTimerExpired() {
    unawaited(
      pause().catchError((Object e) {
        _log.warning('Sleep timer could not pause playback', e);
      }),
    );
    notifyListeners();
  }

  /// Completes once the player released after [dispose] has stopped
  /// reading and writing the audio cache. Null before [dispose].
  Future<void>? get released => _released;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _networkResume = null;
    _move?.complete(_MoveResult.superseded);
    _move = null;
    _signalChange();
    for (final op in _ops) {
      op.done.complete();
    }
    _ops.clear();
    _downloads.cancel();
    unawaited(_positionSubscription?.cancel());
    unawaited(_durationSubscription?.cancel());
    unawaited(_playerStateSubscription?.cancel());
    unawaited(_currentIndexSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());
    unawaited(_commandSubscription?.cancel());
    unawaited(_networkSubscription?.cancel());
    _sleepTimer.dispose();
    // Not disposed here: AppState owns it and keeps it across logins
    _persistence?.flushPendingPositionSave();
    _scrobbleQueue.dispose();
    unawaited(_playbackErrors.close());
    _released = _audioPlayer.dispose().catchError((Object e) {
      _log.warning('Could not release the player', e);
    });
    _position.dispose();
    super.dispose();
  }
}
