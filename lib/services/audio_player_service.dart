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
import 'player_worker.dart';
import 'sleep_timer.dart';
import 'upcoming_downloads.dart';

final _log = Logger('audio_player');
final _rgLogger = Logger('replaygain');

enum PlaybackState { stopped, playing, paused, loading }

/// What the queue was started from. Saved with the queue by its [name].
enum QueueSource { album, random, song }

/// Plays a playlist through [VoidweaverPlayer]. The whole playlist is handed
/// to the player as its sequence, so the player moves from track to track by
/// itself (gaplessly); the service follows its current index. Each item
/// carries its own ReplayGain gain. Every change of the player's track,
/// sequence or position goes through [PlayerWorker]; this service decides
/// what its outcomes and the player's events mean (the current track,
/// scrobbling, saves, gains, errors for the user). See docs/PLAYBACK.md.
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

  // Carries out the track changes on the player and follows its events, see
  // PlayerWorker. It holds the playlist.
  late final PlayerWorker _worker;

  PlaybackState _playbackState = PlaybackState.stopped;
  int _currentIndex = 0;
  // Changes several times a second, so it has its own listenable ([position])
  // instead of notifying the service's listeners
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);
  Duration _totalDuration = Duration.zero;
  Song? _currentSong;

  // Playlist source tracking for persistence
  QueueSource? _playlistSource;
  String? _sourceId;

  // Incremented whenever a new queue is requested (an album, random songs,
  // a song); a start whose songs arrive after a newer request is dropped,
  // see _startQueue()
  int _queueRequests = 0;

  // Skips
  DateTime? _lastSkipTime;
  bool get _skipping => _worker.skipping;

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
    // Before the player's other streams are listened to; it follows the
    // index and error events itself
    _worker = PlayerWorker(_audioPlayer, _WorkerHost(this));
    _initializePlayer();
    unawaited(_scrobbleQueue.initialize());
  }

  /// Loads and skips in progress that were asked to start playback once
  /// their track is ready (0 or 1), see [playWhenReady]
  @visibleForTesting
  int get startsInProgress => _worker.startsPlayback ? 1 : 0;

  /// Changes to the player's index, sequence or position that are running or
  /// queued, see PlayerWorker._work(). While there are any, index events and
  /// the end of the queue wait until they're done.
  @visibleForTesting
  int get pendingPlayerOps => _worker.pendingOps;

  /// Whether the next play() or skip loads the queue again (after stop() or
  /// an error) instead of seeking
  @visibleForTesting
  bool get needsSourceReload => _playlist.isNotEmpty && _worker.needsLoad;

  /// Whether a skip is being carried out. Nothing in the UI depends on it:
  /// the skip buttons stay enabled, a press moves the skip's target, see
  /// _skip().
  @visibleForTesting
  bool get isSkipOperationInProgress => _skipping;

  PlaybackState get playbackState => _playbackState;
  List<Song> get playlist => _playlist;
  List<Song> get _playlist => _worker.playlist;
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
  bool get playWhenReady =>
      _worker.hasMove ? _worker.playPending : _audioPlayer.playing;

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

    _commandSubscription = _audioPlayer.commandStream.listen(_onSystemCommand);

    _playerStateSubscription = _audioPlayer.playerStateStream.listen((state) {
      _log.fine('State changed to: $state');
      switch (state.processingState) {
        case ProcessingState.completed:
          // Not again after _onQueueCompleted() paused the player
          if (state.playing) _worker.playerCompleted();
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

      _worker.setPlaylist(savedState.playlist);
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
        onFailure: OnFailure.quiet,
        description: 'restored song',
      );
      // Playback the user started meanwhile (an album, a skip) took over
      if (result == MoveResult.superseded || result == MoveResult.stopped) {
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
    _worker.setPlaylist(List.of(songs));
    _playlistSource = source;
    _sourceId = sourceId;
    await _startPlaylist(description);
  }

  Future<void> playSong(Song song) async {
    // An album or random still being fetched doesn't replace this one
    ++_queueRequests;
    _worker.setPlaylist([song]);
    _playlistSource = QueueSource.song;
    _sourceId = song.id;
    await _startPlaylist('song');
  }

  /// Plays the new playlist from its start. Completes once it plays (or a
  /// later request took over); throws if it can't be played.
  Future<void> _startPlaylist(String description) async {
    await _requestMove(
      0,
      play: true,
      onFailure: OnFailure.throwToCaller,
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

  /// Asks the worker to move to [index] of the playlist, at [position], and
  /// to start playback there if [play], see [PlayerWorker.requestMove]. The
  /// track becomes current right away (_onMoveRequested()).
  Future<MoveResult> _requestMove(
    int index, {
    Duration position = Duration.zero,
    required bool play,
    required OnFailure onFailure,
    bool skip = false,
    String description = 'song',
    Object? failure,
  }) => _worker.requestMove(
    index,
    position: position,
    play: play,
    onFailure: onFailure,
    skip: skip,
    description: description,
    failure: failure,
  );

  /// A move was requested: the track becomes current right away, so the app
  /// shows it while it loads. Not for error recovery ([Move.failure]), which
  /// stays on the failed track until it finds one to go on at.
  void _onMoveRequested(Move move) {
    _networkResume = null;
    if (move.failure == null) {
      if (_worker.needsLoad) _playbackState = PlaybackState.loading;
      _setCurrentTrack(
        move.index,
        position: move.position,
        playing: move.startsPlayback,
      );
    }
  }

  /// [move] reached its target, which starts playing unless paused.
  void _onMoveReached(Move move) {
    _pendingResumePosition = Duration.zero;
    move.complete(MoveResult.reached);
    _startUnlessPaused();
  }

  /// [move] ended with its [failure], which goes where [Move.onFailure]
  /// says.
  void _onMoveFailed(Move move, Object failure) {
    if (move.index != _currentIndex) {
      _setCurrentTrack(move.index, playing: false);
    }
    switch (move.onFailure) {
      case OnFailure.throwToCaller:
        _pendingResumePosition = Duration.zero;
        _onLoadFailed(
          'Failed to play ${move.description}',
          failure,
          report: false,
        );
        move.fail(failure);
      case OnFailure.report:
        // After a network failure, play() goes on where the track broke off,
        // and so does the network coming back if it was meant to play
        final network = _isNetworkFailure(failure);
        _pendingResumePosition = network ? move.position : Duration.zero;
        if (network && _worker.playPending) {
          _networkResume = (
            generation: _worker.generation,
            index: move.index,
            failedAt: _clock(),
          );
        }
        _onLoadFailed('Failed to play ${move.description}', failure);
        move.complete(MoveResult.failed);
      case OnFailure.quiet:
        // play() loads it again where it was meant to start
        _pendingResumePosition = move.position;
        if (_worker.playPending) {
          // Play was pressed while it loaded: the user is told, as after
          // any other Play
          _onLoadFailed('Failed to play ${move.description}', failure);
        } else {
          _log.warning(
            'Could not load ${move.description}, will retry on play',
            failure,
          );
        }
        move.complete(MoveResult.failed);
    }
  }

  /// stop() ended a load before its track (see PlayerWorker._stopEnds()):
  /// the player stays idle, and play() loads it again.
  void _onMoveStopped() {
    _listening.clearStart();
    if (_audioPlayer.processingState == ProcessingState.idle) {
      _playbackState = PlaybackState.stopped;
    }
    notifyListeners();
  }

  AudioSource _sourceFor(int index, Object tag) {
    final song = _playlist[index];
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

  /// The queue is about to be handed to the player again.
  void _onLoadingSequence() {
    _playbackState = PlaybackState.loading;
    notifyListeners();
  }

  /// Starts playback of the track a move has just reached, unless pause()
  /// was pressed meanwhile. Then it stays paused, and play() starts it as a
  /// new play (like a restored song).
  void _startUnlessPaused() {
    if (!_worker.playPending) {
      _listening.clearStart();
      notifyListeners();
      return;
    }
    // A restored song that Play was pressed for while it loaded
    if (!_listening.hasStarted) _listening.markStarted();
    _startPlayback();
    _onTrackStarted();
  }

  /// The player moved on to the next track at the end of the current one,
  /// see PlayerWorker._followPlayer().
  void _onAdvanced(int index) {
    _listening.listenedToEnd(_currentSongDuration);
    _scrobbleCurrentSongIfEligible();
    _setCurrentTrack(index, playing: true);
    unawaited(_loadReplayGain(index));
    _onTrackStarted();
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

  /// The last track played to its end (see PlayerWorker.playerCompleted()).
  /// The player stays completed with `playing` set, which the system
  /// controls show as playing, and play() does nothing in that state. So
  /// pause at the start of the last track: Play replays it, as a new play
  /// (like a restored song, see play()).
  void _onQueueCompleted() {
    _log.info('End of playlist reached');
    _listening.listenedToEnd(_currentSongDuration);
    _scrobbleCurrentSongIfEligible();
    _setCurrentTrack(_currentIndex, playing: false);
    _playbackState = PlaybackState.paused;
    notifyListeners();
    unawaited(
      _worker
          .queueOp(() async {
            await _audioPlayer.pause();
            await _audioPlayer.seek(Duration.zero);
          })
          .catchError((Object e) {
            _log.warning('Could not rewind after the last track', e);
          }),
    );
  }

  /// The track at [failedIndex] failed to load or play while no move was in
  /// progress (the player is idle now), see PlayerWorker._onPlayerError().
  void _onPlaybackFailed(int failedIndex, PlayerException error) {
    _log.warning('Playback error at index $failedIndex', error);
    _pendingResumePosition = Duration.zero;
    if (_worker.sourcesStale && playWhenReady) {
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
          onFailure: OnFailure.report,
        ),
      );
      return;
    }
    // Continues at the next downloaded track if it was playing; stops on
    // the failed one, reported, if it was paused or nothing later is
    // downloaded. play() tries it again then, where it broke off if the
    // network failed (see _onMoveFailed()).
    unawaited(
      _requestMove(
        failedIndex,
        position: failedIndex == _currentIndex
            ? _currentPosition
            : Duration.zero,
        play: playWhenReady,
        onFailure: OnFailure.report,
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
  /// failed (see _onMoveFailed()), where it broke off, unless the user did
  /// anything with playback since, or it's been too long.
  void _onNetworkAvailable() {
    final resume = _networkResume;
    if (resume == null || _disposed) return;
    _networkResume = null;
    if (_clock().difference(resume.failedAt) > networkResumeWindow) {
      _log.info('Network is back, too long after playback stopped to resume');
      return;
    }
    if (resume.generation != _worker.generation ||
        resume.index != _currentIndex ||
        _worker.hasMove ||
        !_worker.needsLoad) {
      return;
    }
    _log.info('Network is back, resuming index $_currentIndex');
    unawaited(play());
  }

  /// The API's password changed (see [SubsonicApi.usePassword]). Playback
  /// goes on: the player plays cached tracks from the cache whatever their
  /// URL. Downloads of the upcoming tracks start again with the new
  /// password, and an item that fails to stream with the old one loads the
  /// queue again, see _onPlaybackFailed().
  void credentialsChanged() {
    if (_disposed || _playlist.isEmpty) return;
    _worker.markSourcesStale();
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

    if (_worker.hasMove) {
      // Paused during a load or skip (or stopped: a load stop() interrupted
      // loads again): it starts playback once it's done
      _worker.playPending = true;
      notifyListeners();
      return;
    }

    if (_currentSong == null || _worker.needsLoad) {
      await _requestMove(
        _currentIndex,
        position: _pendingResumePosition,
        play: true,
        onFailure: OnFailure.report,
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
    if (_worker.hasMove && _worker.playPending) {
      _worker.playPending = false;
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
  /// its target. See PlayerWorker._stopEnds().
  Future<void> stop() async {
    _networkResume = null;
    _worker.stopRequested();
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
    final skipFrom = _worker.skipTarget;
    final target = targetFrom(skipFrom ?? _currentIndex);
    if (target < 0 || target >= _playlist.length) return;
    if (!_canSkip()) {
      _log.fine('[$source] Skip ignored');
      return;
    }
    if (skipFrom != null) {
      _log.fine('[$source] Skip in progress, continuing to index $target');
      _worker.redirectSkip(target);
      return;
    }
    _scrobbleCurrentSongIfEligible();
    // Replaces a start or error recovery in progress
    await _requestMove(
      target,
      play: true,
      onFailure: OnFailure.report,
      skip: true,
      description: 'song ($source)',
    );
  }

  /// Seeks within the current track. During a load or skip it applies to the
  /// track that one makes current: before the player has been told to go
  /// there, as the position it starts at, otherwise once it's there.
  Future<void> seekTo(Duration position) {
    if (_worker.hasMove) {
      _currentPosition = position;
      // The move's end saves only if it starts playback
      _schedulePositionSave();
      return _worker.seekDuringMove(position);
    }
    if (_playlist.isNotEmpty && _worker.needsLoad) {
      // Nothing loaded to seek in: play() loads it there
      _pendingResumePosition = position;
      _currentPosition = position;
      _schedulePositionSave();
      return Future.value();
    }
    final generation = _worker.generation;
    final index = _currentIndex;
    return _worker.queueOp(() async {
      // The queue was replaced, or the track changed, meanwhile: the position
      // was meant for the track before
      if (generation != _worker.generation || index != _currentIndex) return;
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
    for (final item in _worker.currentItems) {
      if (onlyIndex != null && item.index != onlyIndex) continue;
      if (item.index >= _playlist.length) continue;
      unawaited(
        _audioPlayer
            .setGain(item.source, _gainFor(_playlist[item.index]))
            .catchError((Object e) {
              _rgLogger.warning('Could not set gain', e);
            }),
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
    // Ends the move in progress and the queued operations, and stops
    // following the player's index and error events
    _worker.dispose();
    _downloads.cancel();
    unawaited(_positionSubscription?.cancel());
    unawaited(_durationSubscription?.cancel());
    unawaited(_playerStateSubscription?.cancel());
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

/// The service's side of [PlayerWorker]: forwards to its private methods, so
/// none of them become part of the service's API.
class _WorkerHost implements PlayerWorkerHost {
  final AudioPlayerService _service;

  _WorkerHost(this._service);

  @override
  int get currentIndex => _service._currentIndex;

  @override
  AudioSource sourceFor(int index, Object tag) =>
      _service._sourceFor(index, tag);

  @override
  Future<void> prepare(int index) => _service._loadReplayGain(index);

  @override
  Future<int?> nextCachedIndex(int index) => _service._nextCachedIndex(index);

  @override
  void moveRequested(Move move) => _service._onMoveRequested(move);

  @override
  void retargeted(int index) => _service._setCurrentTrack(index, playing: true);

  @override
  void loadingSequence() => _service._onLoadingSequence();

  @override
  void passingThrough() => _service._scrobbleCurrentSongIfEligible();

  @override
  void moveReached(Move move) => _service._onMoveReached(move);

  @override
  void moveFailed(Move move, Object failure) =>
      _service._onMoveFailed(move, failure);

  @override
  void moveStopped() => _service._onMoveStopped();

  @override
  void advanced(int index) => _service._onAdvanced(index);

  @override
  void queueCompleted() => _service._onQueueCompleted();

  @override
  void playbackFailed(int index, PlayerException error) =>
      _service._onPlaybackFailed(index, error);
}
