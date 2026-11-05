import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:voidweaver_player/voidweaver_player.dart';
import 'package:logging/logging.dart';

import 'subsonic_api.dart';
import 'settings_service.dart';
import 'replaygain_reader.dart';
import 'replaygain_debug_logger.dart';
import 'playback_persistence.dart';
import 'scrobble_queue.dart';
import 'audio_cache.dart';
import 'network_errors.dart';
import 'listening_tracker.dart';
import 'sleep_timer.dart';

final _log = Logger('audio_player');
final _rgLogger = Logger('replaygain');

enum PlaybackState { stopped, playing, paused, loading }

/// What the queue was started from. Saved with the queue by its [name].
enum QueueSource { album, random, song }

/// Identifies an item in the player's sequence: the playlist position it
/// stands for, and the [AudioPlayerService._loadQueue] call that created it.
/// Set as each source's tag, so index events map back to songs even while
/// the sequence is being changed.
class _QueueEntry {
  final int generation;
  final int index;

  const _QueueEntry(this.generation, this.index);
}

/// Plays a playlist through [VoidweaverPlayer]. The whole playlist is handed
/// to the player as its sequence, so the player moves from track to track by
/// itself (gaplessly); the service follows its current index. Each item
/// carries its own ReplayGain gain. See docs/PLAYBACK.md.
class AudioPlayerService extends ChangeNotifier {
  /// Upcoming tracks downloaded to the cache while playing
  static const int _maxPreloadTracks = 3;

  /// Skips within this time of the previous one are ignored, as a doubled
  /// event rather than another press
  static const _skipDebounceMs = 100;

  /// How long the current track has to have played for Previous to restart
  /// it instead of going back a track
  static const _restartThreshold = Duration(seconds: 3);

  /// Retries of a failed download, see _preloadUpcomingSongs(). The delay
  /// before each retry doubles: 5 s, 10 s, ... about 2.5 minutes in all.
  static const _maxDownloadRetries = 5;

  final VoidweaverPlayer _audioPlayer;
  final SubsonicApi _api;
  final SettingsService _settingsService;
  final PlaybackPersistenceService? _persistence;
  final ScrobbleQueue _scrobbleQueue;
  final AudioCache _audioCache;
  final Duration _downloadRetryDelay;
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

  // Incremented whenever the player's sequence is replaced. Sources and
  // events from an older generation are ignored.
  int _generation = 0;

  // Incremented whenever a new queue is requested (an album, random songs,
  // a song); a start whose songs arrive after a newer request is dropped,
  // see _startQueue()
  int _queueRequests = 0;

  // Changes to the player's index or sequence run one at a time, see
  // _playerOp(). While one runs, index events are ignored.
  Future<void> _playerOps = Future.value();
  int _pendingPlayerOps = 0;
  // Set while setAudioSources() runs; its load errors are thrown, not handled
  // through the error stream
  bool _settingSources = false;
  // A playback error reported while a player operation was running
  PlayerException? _deferredError;
  // The index _jumpTo() seeked to, until the player reports it. Until then,
  // an index event can still be from before the seek: after previous(), the
  // old track's index would look like an advance.
  int? _awaitedIndex;
  // The _loadQueue() call that hasn't handed its sequence to the player yet,
  // and where a seek meanwhile moved its start, see seekTo()
  int? _preparingLoad;
  Duration? _seekBeforeLoad;

  // Skips
  DateTime? _lastSkipTime;
  bool _skipOperationInProgress = false;
  // Where the skip in progress ends up; presses meanwhile move it, see _skip()
  int? _skipTarget;

  // Loads and skips that start playback once their track is ready
  // (_loadQueue() with `play`, _jumpTo()), and whether they still should:
  // pause() during one clears it, play() sets it again
  int _startsInProgress = 0;
  bool _playPending = false;

  // Set when a song couldn't be loaded (e.g. offline at startup); the queue
  // is loaded again on the next play()
  bool _needsSourceReload = false;
  Duration _pendingResumePosition = Duration.zero;

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

  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<int?>? _currentIndexSubscription;
  StreamSubscription<PlayerException>? _errorSubscription;
  StreamSubscription<SystemCommand>? _commandSubscription;

  // Incremented whenever downloads of upcoming tracks start; an older run
  // stops, see _preloadUpcomingSongs()
  int _preloadRun = 0;

  // Async work (preloads, ReplayGain reads) can finish after dispose()
  bool _disposed = false;

  AudioPlayerService(
    this._api,
    this._settingsService, {
    VoidweaverPlayer? audioPlayer,
    this._persistence,
    ScrobbleQueue? scrobbleQueue,
    AudioCache? audioCache,
    @visibleForTesting this._downloadRetryDelay = const Duration(seconds: 5),
    @visibleForTesting this._clock = DateTime.now,
  }) : _audioPlayer = audioPlayer ?? VoidweaverPlayer(),
       _scrobbleQueue = scrobbleQueue ?? ScrobbleQueue(_api),
       _audioCache = audioCache ?? AudioCache() {
    _initializePlayer();
    unawaited(_scrobbleQueue.initialize());
  }

  /// Whether a skip is being carried out; the UI disables the skip buttons.
  bool get isSkipOperationInProgress => _skipOperationInProgress;

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
  bool get playWhenReady =>
      _startsInProgress > 0 ? _playPending : _audioPlayer.playing;

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
          if (state.playing) _onQueueCompleted();
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

      _playlist = savedState.playlist;
      _playlistSource = QueueSource.values
          .asNameMap()[savedState.playlistSource];
      _sourceId = savedState.sourceId;
      final resumeAt = savedState.currentPosition;

      // Load the queue but don't auto-play. If that fails (e.g. the server
      // is unreachable) keep the restored queue and retry on play().
      final loading = _loadQueue(
        savedState.currentIndex,
        position: resumeAt,
        play: false,
      );
      final generation = _generation;
      try {
        await loading;
      } catch (e) {
        if (generation == _generation) {
          _log.warning('Could not load restored song, will retry on play', e);
          _needsSourceReload = true;
          _pendingResumePosition = resumeAt;
        }
      }
      // Playback the user started meanwhile (an album, or Play) took over
      if (generation != _generation) return false;
      _currentPosition = resumeAt;
      _playbackState = PlaybackState.paused; // User must manually resume

      _log.info(
        'Successfully restored playback state: ${_currentSong?.title} at $resumeAt',
      );
      notifyListeners();
      return true;
    } catch (e) {
      _log.warning('Failed to restore playback state', e);
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
    _playlist = List.of(songs);
    _playlistSource = source;
    _sourceId = sourceId;
    try {
      await _loadQueue(0);
    } catch (e) {
      _onLoadFailed('Failed to play $description: $e');
      rethrow;
    }
  }

  Future<void> playSong(Song song) async {
    // An album or random still being fetched doesn't replace this one
    ++_queueRequests;
    _playlist = [song];
    _playlistSource = QueueSource.song;
    _sourceId = song.id;
    try {
      await _loadQueue(0);
    } catch (e) {
      _onLoadFailed('Failed to play song: $e');
      rethrow;
    }
  }

  void _onLoadFailed(String message) {
    _log.warning(message);
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

  /// Runs [change] to the player's index or sequence after earlier changes
  /// finished. Index events are ignored while it runs (they can report a
  /// state from before the change), and the service catches up with the
  /// player afterwards.
  Future<T> _playerOp<T>(Future<T> Function() change) {
    _pendingPlayerOps++;
    final result = _playerOps.then((_) => change());
    _playerOps = result.then<void>((_) {}, onError: (_) {});
    return result.whenComplete(() {
      _pendingPlayerOps--;
      if (_pendingPlayerOps > 0 || _disposed) return;
      final error = _deferredError;
      _deferredError = null;
      if (error != null) {
        _onPlayerError(error);
      } else {
        _followPlayer();
      }
    });
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
  /// the rest. If the start track can't be loaded and [play] is set,
  /// continues from the next cached track. A pause() meanwhile cancels [play]:
  /// the track stays loaded, paused.
  Future<void> _loadQueue(
    int startIndex, {
    Duration position = Duration.zero,
    bool play = true,
  }) async {
    final generation = ++_generation;
    _awaitedIndex = null;
    _preparingLoad = generation;
    _seekBeforeLoad = null;
    _playPending = play;
    if (play) _startsInProgress++;
    try {
      _setCurrentTrack(startIndex, position: position, playing: play);
      _playbackState = PlaybackState.loading;
      notifyListeners();
      // Before creating the sources, so the start track gets its own gain
      await _loadReplayGain(startIndex);
      if (generation != _generation) return;

      final sources = [
        for (var i = 0; i < _playlist.length; i++) _sourceFor(generation, i),
      ];
      _sourcesStale = false;

      try {
        await _playerOp(() async {
          if (generation != _generation) return;
          // Later seeks wait for this operation
          final start = _seekBeforeLoad ?? position;
          _preparingLoad = null;
          _seekBeforeLoad = null;
          _settingSources = true;
          try {
            await _audioPlayer.setAudioSources(
              sources,
              initialIndex: startIndex,
              initialPosition: start,
            );
          } finally {
            _settingSources = false;
          }
        });
      } on PlayerInterruptedException {
        // A newer _loadQueue() replaced the sequence
        return;
      } catch (e) {
        if (generation != _generation) return;
        final next = _playPending ? await _nextCachedIndex(startIndex) : null;
        if (generation != _generation) return;
        if (next == null) rethrow;
        _log.warning(
          '[offline] Could not load index $startIndex, continuing at cached index $next',
        );
        return await _loadQueue(next, play: _playPending);
      }
      if (generation != _generation) return;

      _needsSourceReload = false;
      if (play) _startUnlessPaused();
    } finally {
      if (play) _startsInProgress--;
    }
  }

  /// Starts playback of the track a load or skip has just made current,
  /// unless pause() was pressed meanwhile. Then it stays paused, and play()
  /// starts it as a new play (like a restored song).
  void _startUnlessPaused() {
    if (!_playPending) {
      _listening.clearStart();
      notifyListeners();
      return;
    }
    _startPlayback();
    _onTrackStarted();
  }

  /// Moves playback to [index] within the current sequence.
  Future<void> _jumpTo(int index) async {
    // After stop() or an error the player has to load again
    if (_needsSourceReload ||
        _audioPlayer.processingState == ProcessingState.idle) {
      return _loadQueue(index);
    }

    final generation = _generation;
    _playPending = true;
    _startsInProgress++;
    try {
      // Inside the operation, so an index event for the old track arriving
      // meanwhile isn't taken for an advance from the new one
      await _playerOp(() async {
        if (generation != _generation) return;
        _setCurrentTrack(index, playing: true);
        // Before seeking, so the track starts at its own gain
        await _loadReplayGain(index);
        if (generation != _generation) return;
        _awaitedIndex = index;
        await _seekToItem(index);
      });
      // The target failed to load: _onPlayerError() takes over, continuing
      // at a cached track or stopping on this one
      if (generation != _generation ||
          _currentIndex != index ||
          _needsSourceReload) {
        return;
      }

      _startUnlessPaused();
    } finally {
      _startsInProgress--;
    }
  }

  /// Seeks to the start of the item at [index]. The player's seek() completes
  /// once the item is ready or has failed; a seek that never completed would
  /// block all later player operations, so this also returns once the player
  /// reports an error or goes idle. The error is handled after the operation,
  /// see _playerOp().
  Future<void> _seekToItem(int index) async {
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
        _audioPlayer.seek(Duration.zero, index: index),
        failed.future,
      ]);
    } finally {
      await errors.cancel();
      await idle.cancel();
    }
  }

  /// Catches up with the player's current item. Called on index events and
  /// after each player operation; only an advance by one, which the player
  /// makes at the end of a track, needs following.
  void _followPlayer() {
    if (_pendingPlayerOps > 0 || _disposed) return;
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
    final sequence = _audioPlayer.sequence;
    if (sequenceIndex == null || sequenceIndex >= sequence.length) return null;
    final tag = sequence[sequenceIndex].tag;
    if (tag is! _QueueEntry || tag.generation != _generation) return null;
    return tag;
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
      _playerOp(() async {
        await _audioPlayer.pause();
        await _audioPlayer.seek(Duration.zero);
      }).catchError((Object e) {
        _log.warning('Could not rewind after the last track', e);
      }),
    );
  }

  void _onPlayerError(PlayerException error) {
    // setAudioSources() throws its errors, see _loadQueue()
    if (_settingSources || _disposed) return;
    if (_pendingPlayerOps > 0) {
      _deferredError = error;
      return;
    }

    final failedIndex = _entryAt(error.index)?.index ?? _currentIndex;
    _log.warning('Playback error at index $failedIndex', error);
    // The player is idle after an error: whatever plays next loads the queue
    // again. Set right away, so _jumpTo() doesn't take its target for started.
    _needsSourceReload = true;
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
        _loadQueue(
          failedIndex,
          position: position,
        ).catchError((Object e) => _onLoadFailed('Failed to play song: $e')),
      );
      return;
    }
    unawaited(_continueAfterError(failedIndex, error, resume: playWhenReady));
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

  /// Continues at the next cached track after [failedIndex] if [resume] is
  /// set (it isn't when the track failed while paused), or stops on it.
  Future<void> _continueAfterError(
    int failedIndex,
    PlayerException error, {
    required bool resume,
  }) async {
    final generation = _generation;
    final next = resume ? await _nextCachedIndex(failedIndex) : null;
    // The queue was replaced, or a skip took over, while looking
    if (_disposed || generation != _generation || _pendingPlayerOps > 0) {
      return;
    }
    if (next != null) {
      _log.info('[offline] Continuing at cached index $next');
      try {
        await _jumpTo(next);
      } catch (e) {
        _onLoadFailed('Failed to play song: $e');
      }
      return;
    }

    // Nothing later is playable; play() tries this track again
    if (failedIndex != _currentIndex) {
      _setCurrentTrack(failedIndex, playing: false);
    }
    _onLoadFailed('Failed to play song: ${error.message ?? error}');
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

    if (_startsInProgress > 0) {
      // Paused during a load or skip: it starts playback once it's done
      _playPending = true;
      notifyListeners();
      return;
    }

    if (_currentSong == null ||
        _needsSourceReload ||
        _audioPlayer.processingState == ProcessingState.idle) {
      final position = _needsSourceReload ? _pendingResumePosition : null;
      try {
        await _loadQueue(_currentIndex, position: position ?? _currentPosition);
      } catch (e) {
        _onLoadFailed('Failed to play song: $e');
      }
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
    if (_startsInProgress > 0 && _playPending) {
      _playPending = false;
      notifyListeners();
    }
    await _audioPlayer.pause();
  }

  Future<void> stop() async {
    _playPending = false;
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
    final restart =
        !_skipOperationInProgress && _currentPosition > _restartThreshold;
    return restart ? from : max(from - 1, 0);
  });

  /// Skips to the index [targetFrom] returns for the current one or, while a
  /// skip is in progress, for its target. A press during a skip doesn't start
  /// another one but moves the target, and the skip continues there once it
  /// has reached its earlier target. So pressing Next three times moves three
  /// tracks, however long each takes to load.
  Future<void> _skip(String source, int Function(int from) targetFrom) async {
    final target = targetFrom(_skipTarget ?? _currentIndex);
    if (target < 0 || target >= _playlist.length) return;
    if (!_canSkip()) {
      _log.fine('[$source] Skip ignored');
      return;
    }
    if (_skipOperationInProgress) {
      _log.fine('[$source] Skip in progress, continuing to index $target');
      _skipTarget = target;
      return;
    }

    final playlist = _playlist;
    _skipTarget = target;
    _skipOperationInProgress = true;
    notifyListeners();
    try {
      int? reached;
      // Ends early if a new queue was started meanwhile
      while (_skipTarget != reached && identical(playlist, _playlist)) {
        reached = _skipTarget!;
        _scrobbleCurrentSongIfEligible();
        await _jumpTo(reached);
      }
    } catch (e) {
      _log.warning('[$source] Error during skip', e);
      _onLoadFailed('Failed to play song: $e');
    } finally {
      _skipTarget = null;
      _skipOperationInProgress = false;
      notifyListeners();
    }
  }

  /// Seeks within the current track. After a load or skip in progress, so
  /// it lands on the track that one makes current rather than the one before
  /// it, and isn't overwritten by its start position.
  Future<void> seekTo(Duration position) {
    if (_preparingLoad == _generation) {
      // The load hasn't set its sequence yet: start it there instead
      _seekBeforeLoad = position;
      _currentPosition = position;
      return Future.value();
    }
    final generation = _generation;
    final index = _currentIndex;
    return _playerOp(() async {
      // The queue was replaced, or the track changed, meanwhile: the position
      // was meant for the track before
      if (generation != _generation || index != _currentIndex) return;
      await _audioPlayer.seek(position);
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
    final song = playlist[index];
    logReplayGain(
      () =>
          '[ReplayGain] Processing song: "${song.title}" by "${song.artist}" '
          '(id=${song.id}, album="${song.album}", format=${song.suffix}/${song.contentType})',
    );

    if (song.replayGainTrackGain == null && song.replayGainAlbumGain == null) {
      logReplayGain(
        () =>
            '[ReplayGain] No ReplayGain in API response, reading from file...',
      );
      try {
        final data =
            await _audioCache.readReplayGain(song) ??
            await _api.readReplayGain(song.id);
        logReplayGain(
          () =>
              '[ReplayGain] File reading complete: '
              'TrackGain=${data.trackGain?.toStringAsFixed(2) ?? "null"}, '
              'AlbumGain=${data.albumGain?.toStringAsFixed(2) ?? "null"}, '
              'TrackPeak=${data.trackPeak?.toStringAsFixed(4) ?? "null"}, '
              'AlbumPeak=${data.albumPeak?.toStringAsFixed(4) ?? "null"}',
        );
        _storeReplayGain(playlist, index, data);
      } catch (e, stackTrace) {
        logReplayGain(
          () => '[ReplayGain] ERROR reading ReplayGain metadata: $e',
        );
        logReplayGain(() => '[ReplayGain] Stack trace: $stackTrace');
      }
    }

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

  /// The linear gain [song] plays at, from its ReplayGain data and the
  /// settings. Smart mode uses the album gain when the queue is an album.
  double _gainFor(Song song) => _settingsService.calculateVolumeAdjustment(
    trackGain: song.replayGainTrackGain,
    albumGain: song.replayGainAlbumGain,
    trackPeak: song.replayGainTrackPeak,
    albumPeak: song.replayGainAlbumPeak,
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
    if (song == null || !replayGainLogging) return;
    for (final line in trackGainReport(
      song,
      _settingsService,
      gain: _gainFor(song),
      queue: _playlistSource?.name ?? 'none',
    )) {
      logReplayGain(() => line);
    }
  }

  /// Applies changed ReplayGain settings to every track in the queue.
  Future<void> refreshReplayGainVolume() async {
    _updateGains();
    _logReplayGain();
  }

  /// Downloads upcoming songs in the playlist to the cache so playback can
  /// continue if the network drops; the player plays them from there.
  /// Downloads run one at a time, nearest track first, so the next song is
  /// ready as early as possible.
  ///
  /// A failed download (e.g. the network dropped for a moment) is tried
  /// again a few times. Otherwise the player would have to stream the track
  /// when it gets there, and a network drop at that moment stops playback.
  Future<void> _preloadUpcomingSongs() async {
    final run = ++_preloadRun;
    final playlist = _playlist;
    final start = _currentIndex + 1;
    final end = (start + _maxPreloadTracks).clamp(0, playlist.length);
    if (start >= end) return;

    // Stop once the playlist is replaced or another track started (which
    // starts its own downloads)
    bool current() =>
        !_disposed && run == _preloadRun && identical(playlist, _playlist);

    for (var index = start; index < end; index++) {
      var delay = _downloadRetryDelay;
      for (var attempt = 0; current(); attempt++) {
        if (await _preloadSingleTrack(playlist, index) ||
            attempt == _maxDownloadRetries) {
          break;
        }
        await Future.delayed(delay);
        delay *= 2;
      }
      if (!current()) break;
    }
  }

  /// Downloads the track at [index] and reads its ReplayGain metadata from
  /// the cache if the server didn't provide it. Returns whether the track is
  /// completely cached.
  Future<bool> _preloadSingleTrack(List<Song> playlist, int index) async {
    final song = playlist[index];
    if (!await _audioCache.prefetch(song, _api.getStreamUrl(song.id))) {
      return false;
    }
    if (song.replayGainTrackGain != null || song.replayGainAlbumGain != null) {
      return true;
    }
    final data = await _audioCache.readReplayGain(song);
    if (data == null) return true;
    logReplayGain(
      () =>
          '[ReplayGain] Preload read "${song.title}": Track=${data.trackGain}, Album=${data.albumGain}',
    );
    _storeReplayGain(playlist, index, data);
    return true;
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

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_positionSubscription?.cancel());
    unawaited(_durationSubscription?.cancel());
    unawaited(_playerStateSubscription?.cancel());
    unawaited(_currentIndexSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());
    unawaited(_commandSubscription?.cancel());
    _sleepTimer.dispose();
    // Not disposed here: AppState owns it and keeps it across logins
    _persistence?.flushPendingPositionSave();
    _scrobbleQueue.dispose();
    unawaited(
      _audioPlayer.dispose().catchError((Object e) {
        _log.warning('Could not release the player', e);
      }),
    );
    _position.dispose();
    super.dispose();
  }
}
