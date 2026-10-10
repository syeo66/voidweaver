import 'dart:async';
import 'dart:io';
import 'package:just_audio/just_audio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'subsonic_api.dart';
import 'settings_service.dart';
import 'replaygain_reader.dart';
import 'replaygain_debug_logger.dart';
import 'playback_persistence.dart';
import 'scrobble_queue.dart';
import 'audio_cache.dart';

enum PlaybackState {
  stopped,
  playing,
  paused,
  loading,
}

enum AudioLoadingState {
  idle,
  loadingAlbum,
  loadingRandomSongs,
  loadingSong,
  preloading,
  error,
}

/// Tracks position updates with timestamps for stuck playhead detection.
/// Used to analyze position movement patterns and identify when playhead stops
/// advancing during the final seconds of a song (indicating streaming/buffering issues).
class _PositionUpdate {
  final Duration position;
  final DateTime timestamp;

  _PositionUpdate(this.position, this.timestamp);
}

class AudioPlayerService extends ChangeNotifier {
  // End-of-song detection configuration constants
  // These constants configure the enhanced triple-detection mechanism for song completion:
  // 1. Traditional detection: triggers when within 500ms of song end (see _checkManualCompletion)
  // 2. Stuck playhead detection: identifies when position stops moving in near-end zone
  // 3. Stop-based detection: triggers when playback stops within 2s of end (see _checkCompletionOnStop)

  /// Time window (ms) to analyze recent position updates for stuck playhead detection
  static const int _stuckPositionTimeoutMs = 2000;

  /// Zone from song end where stuck playhead detection becomes active (prevents false positives early in songs)
  static const Duration _nearEndThreshold = Duration(seconds: 2);

  /// Minimum position change expected over time periods (used to identify "stuck" playhead)
  static const Duration _minPositionMovement = Duration(milliseconds: 100);

  /// Minimum duration position must appear stuck before triggering completion (prevents glitch detection)
  static const int _minStuckDurationMs = 1000;

  /// Maximum position updates retained in memory for movement analysis (prevents memory growth)
  static const int _maxPositionHistorySize = 10;

  final AudioPlayer _audioPlayer;
  final SubsonicApi _api;
  final SettingsService _settingsService;
  final PlaybackPersistenceService? _persistence;
  final ScrobbleQueue _scrobbleQueue;
  final AudioCache _audioCache;
  final bool _ownsAudioCache;

  PlaybackState _playbackState = PlaybackState.stopped;
  List<Song> _playlist = [];
  int _currentIndex = 0;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  Song? _currentSong;

  // Playlist source tracking for persistence
  String? _playlistSource;
  String? _sourceId;

  // Skip debouncing and operation control
  DateTime? _lastSkipTime;
  static const _skipDebounceMs = 200;
  bool _skipOperationInProgress = false;
  String? _lastSkipSource;

  // Manual completion tracking to prevent duplicate manual completions
  String? _lastManualCompletedSongId;

  // Position tracking for stuck playhead detection
  final List<_PositionUpdate> _recentPositions = [];

  // Index tracking for debugging double-skips
  int _confirmedIndex = 0; // Index of song that actually started playing
  final List<String> _indexChangeLog = [];
  String?
      _lastCompletedSongId; // Track which song last completed to prevent duplicate completions
  DateTime? _currentSongStartTime;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _playerCompleteSubscription;
  StreamSubscription? _playerStateSubscription;
  StreamSubscription? _currentIndexSubscription;

  // Gapless playback: once the next track is cached on disk it's appended to
  // the player's sequence, so the player moves on to it without a gap. The
  // sequence holds at most [current track, next track].
  int? _queuedNextIndex;
  // Sources requested through _loadSource() that haven't finished loading
  int _pendingLoads = 0;
  // Serializes changes to the player's sequence
  Future<void> _sourceChange = Future.value();

  // Enhanced loading states
  AudioLoadingState _audioLoadingState = AudioLoadingState.idle;
  String? _audioLoadingError;

  // Upcoming tracks are downloaded to the disk cache for offline playback
  int _activePreloads = 0;
  static const int _maxPreloadTracks = 3;

  // Set when a restored song couldn't be loaded (e.g. offline at startup);
  // the source is loaded again on the next play()
  bool _needsSourceReload = false;
  Duration _pendingResumePosition = Duration.zero;

  // Sleep timer state
  Timer? _sleepTimer;
  Duration? _sleepTimerDuration;
  DateTime? _sleepTimerStartTime;
  bool _isSleepTimerActive = false;

  // Whether the current play of the current song has been scrobbled
  bool _currentSongScrobbled = false;

  // Async work (preloads, ReplayGain reads) can finish after dispose()
  bool _disposed = false;

  AudioPlayerService(this._api, this._settingsService,
      {AudioPlayer? audioPlayer,
      PlaybackPersistenceService? persistence,
      ScrobbleQueue? scrobbleQueue,
      AudioCache? audioCache})
      : _audioPlayer = audioPlayer ?? AudioPlayer(),
        _persistence = persistence,
        _scrobbleQueue = scrobbleQueue ?? ScrobbleQueue(_api),
        _audioCache = audioCache ?? AudioCache(),
        _ownsAudioCache = audioCache == null {
    _initializePlayer();
    _scrobbleQueue.initialize();
    _audioCache.initialize();
  }

  // Expose AudioPlayer for direct state access by VoidweaverAudioHandler
  AudioPlayer get audioPlayer => _audioPlayer;

  // Expose skip operation state to VoidweaverAudioHandler for state masking
  bool get isSkipOperationInProgress => _skipOperationInProgress;

  PlaybackState get playbackState => _playbackState;
  List<Song> get playlist => _playlist;
  int get currentIndex => _currentIndex;
  Duration get currentPosition => _currentPosition;
  Duration get totalDuration => _totalDuration;
  Song? get currentSong => _currentSong;
  bool get hasNext => _currentIndex < _playlist.length - 1;
  bool get hasPrevious => _currentIndex > 0;
  bool get isPreloading => _activePreloads > 0;
  Song? get preloadedSong =>
      hasPreloadedAudio ? _playlist[_currentIndex + 1] : null;
  bool get hasPreloadedAudio =>
      hasNext && _audioCache.isCached(_playlist[_currentIndex + 1].id);
  int get preloadedTrackCount => [
        for (var i = _currentIndex + 1;
            i < _playlist.length && i <= _currentIndex + _maxPreloadTracks;
            i++)
          if (_audioCache.isCached(_playlist[i].id)) i
      ].length;

  // Enhanced loading state getters
  AudioLoadingState get audioLoadingState => _audioLoadingState;
  String? get audioLoadingError => _audioLoadingError;

  // Sleep timer getters
  bool get isSleepTimerActive => _isSleepTimerActive;
  Duration? get sleepTimerDuration => _sleepTimerDuration;
  Duration? get sleepTimerRemaining {
    if (!_isSleepTimerActive ||
        _sleepTimerStartTime == null ||
        _sleepTimerDuration == null) {
      return null;
    }
    final elapsed = DateTime.now().difference(_sleepTimerStartTime!);
    final remaining = _sleepTimerDuration! - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  // Position stream for real-time updates
  Stream<Duration> get onPositionChanged => _audioPlayer.positionStream;

  // Index change tracking
  void _logIndexChange(
      String operation, int fromIndex, int toIndex, String reason) {
    final timestamp = DateTime.now().toIso8601String();
    final logEntry =
        '[$timestamp] $operation: $fromIndex -> $toIndex ($reason)';
    _indexChangeLog.add(logEntry);
    if (_indexChangeLog.length > 20) {
      _indexChangeLog.removeAt(0); // Keep only last 20 entries
    }
    debugPrint('[INDEX_CHANGE] $logEntry');
  }

  void _printIndexChangeLog() {
    debugPrint('[INDEX_LOG] Recent index changes:');
    for (final entry in _indexChangeLog) {
      debugPrint('[INDEX_LOG] $entry');
    }
  }

  void _initializePlayer() {
    _positionSubscription = _audioPlayer.positionStream.listen((position) {
      _currentPosition = position;

      // Track position updates for stuck playhead detection
      _trackPositionUpdate(position);

      // Manual completion detection as fallback
      _checkManualCompletion(position);

      // Check for automatic scrobbling during playback
      if (_playbackState == PlaybackState.playing) {
        _scrobbleCurrentSongIfEligible();
      }

      // Throttled position saving during playback
      if (_playbackState == PlaybackState.playing) {
        _schedulePositionSave();
      }

      notifyListeners();
    });

    _durationSubscription = _audioPlayer.durationStream.listen((duration) {
      _totalDuration = duration ?? Duration.zero;
      notifyListeners();
    });

    _playerCompleteSubscription =
        _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        debugPrint('[audio_player] onPlayerComplete event fired');
        _onSongComplete();
      }
    });

    _currentIndexSubscription = _audioPlayer.currentIndexStream.listen((index) {
      if (index == 1 && _queuedNextIndex != null) {
        _onGaplessTransition();
      }
    });

    _playerStateSubscription = _audioPlayer.playerStateStream.listen((state) {
      debugPrint(
          '[audio_player] State changed to: $state (skipInProgress: $_skipOperationInProgress)');

      // Handle playing state
      if (state.playing && state.processingState != ProcessingState.completed) {
        _playbackState = PlaybackState.playing;
        debugPrint('[audio_player] Set state to PLAYING');
      }
      // Handle non-playing states
      else if (!state.playing) {
        switch (state.processingState) {
          case ProcessingState.idle:
            if (!_skipOperationInProgress) {
              _playbackState = PlaybackState.stopped;
              debugPrint('[audio_player] Set state to STOPPED');
            } else {
              debugPrint(
                  '[audio_player] Idle state ignored during skip operation');
              // Don't return here - still notify listeners but don't change state
            }
            break;
          case ProcessingState.loading:
          case ProcessingState.buffering:
            _playbackState = PlaybackState.loading;
            debugPrint('[audio_player] Set state to LOADING');
            break;
          case ProcessingState.ready:
            // This is the key fix: ready + not playing = paused
            _playbackState = PlaybackState.paused;
            debugPrint('[audio_player] Set state to PAUSED');

            // Additional completion detection: if we're paused/stopped very close to the end,
            // check if this should trigger completion (handles cases where position stream
            // stops updating before completion event fires)
            _checkCompletionOnStop();
            break;
          case ProcessingState.completed:
            // Don't handle completion here - handled in separate subscription
            debugPrint(
                '[audio_player] Completed state ignored - handled by completion listener');
            return;
        }
      }
      notifyListeners();
    });
  }

  // Persistence methods
  Future<bool> restorePlaybackState() async {
    if (_persistence == null) {
      debugPrint('Persistence service not available, skipping restoration');
      return false;
    }

    try {
      final savedState = await _persistence!.loadPlaybackState();
      if (savedState == null || savedState.isEmpty) {
        debugPrint('No saved playback state to restore');
        return false;
      }

      debugPrint(
          'Attempting to restore playlist with ${savedState.playlist.length} songs');

      // Validate playlist integrity first
      await _validatePlaylist(savedState.playlist);

      // Restore state
      _playlist = savedState.playlist;
      _currentIndex = savedState.currentIndex;
      _confirmedIndex = savedState.currentIndex;
      _playlistSource = savedState.playlistSource;
      _sourceId = savedState.sourceId;

      if (savedState.hasValidIndex) {
        _currentSong = savedState.currentSong;
        final resumeAt = savedState.currentPosition;
        _currentPosition = resumeAt;
        // Not set until playback actually resumes, see play()
        _currentSongStartTime = null;

        // Past the threshold the song was already scrobbled before the app
        // closed (the scrobble queue persists it), so don't scrobble it again.
        final songDuration = Duration(seconds: _currentSong!.duration ?? 0);
        _currentSongScrobbled =
            _hasReachedScrobbleThreshold(resumeAt, songDuration);

        // Set up audio source but don't auto-play. If that fails (e.g. the
        // server is unreachable) keep the restored queue and retry on play().
        try {
          // Load at the saved position rather than seeking afterwards: a
          // seek right after loading can be overtaken by load events still
          // reporting position zero, leaving the playhead at 0:00.
          final streamUrl = await _loadSource(_currentSong!, resumeAt);

          // Apply ReplayGain volume adjustment to ensure settings are applied after restoration
          await _readReplayGainAndApplyVolume(streamUrl,
              cachedFile: _audioCache.getCachedFile(_currentSong!.id));
          unawaited(_queueNextTrack());
        } catch (e) {
          debugPrint('Could not load restored song, will retry on play: $e');
          _needsSourceReload = true;
          _pendingResumePosition = resumeAt;
        }
        _currentPosition = resumeAt;

        // Restore playback state (but don't auto-play)
        _playbackState = PlaybackState.paused; // User must manually resume

        debugPrint(
            'Successfully restored playback state: ${savedState.currentSong?.title} at ${savedState.currentPosition}');
        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('Failed to restore playback state: $e');
      // Clear invalid saved state
      await _persistence?.clearPlaybackState();
    }

    return false;
  }

  Future<void> _validatePlaylist(List<Song> playlist) async {
    // Quick validation: check if first few songs still exist on server
    const maxChecks = 3;
    final checksToPerform =
        playlist.length < maxChecks ? playlist.length : maxChecks;

    for (int i = 0; i < checksToPerform; i++) {
      final song = playlist[i];
      try {
        // Simple check: try to get stream URL (this validates song exists)
        _api.getStreamUrl(song.id);
      } catch (e) {
        throw Exception('Saved playlist contains invalid songs');
      }
    }
  }

  Future<void> _saveCurrentState() async {
    if (_persistence == null || _playlist.isEmpty) return;

    final state = PersistedPlaybackState(
      playlist: _playlist,
      currentIndex: _currentIndex,
      currentPosition: _currentPosition,
      isPlaying: _playbackState == PlaybackState.playing,
      lastUpdated: DateTime.now(),
      playlistSource: _playlistSource,
      sourceId: _sourceId,
    );

    await _persistence!.savePlaybackState(state);
  }

  void _schedulePositionSave() {
    if (_persistence == null || _playlist.isEmpty) return;

    final state = PersistedPlaybackState(
      playlist: _playlist,
      currentIndex: _currentIndex,
      currentPosition: _currentPosition,
      isPlaying: _playbackState == PlaybackState.playing,
      lastUpdated: DateTime.now(),
      playlistSource: _playlistSource,
      sourceId: _sourceId,
    );

    _persistence!.schedulePositionSave(state);
  }

  Future<void> playAlbum(Album album) async {
    try {
      _playbackState = PlaybackState.loading;
      _audioLoadingState = AudioLoadingState.loadingAlbum;
      _audioLoadingError = null;
      notifyListeners();

      if (album.songs.isEmpty) {
        debugPrint(
            'Album ${album.name} has no songs, trying to fetch from API...');
        try {
          final fullAlbum = await _api.getAlbum(album.id);
          _playlist = fullAlbum.songs;
        } catch (e) {
          debugPrint('Failed to fetch album details: $e');
          // If we can't get album details, we can't play it
          _playbackState = PlaybackState.stopped;
          _audioLoadingState = AudioLoadingState.error;
          _audioLoadingError = 'Could not load album songs: ${e.toString()}';
          notifyListeners();
          throw Exception('Could not load album songs: ${e.toString()}');
        }
      } else {
        _playlist = album.songs;
      }

      if (_playlist.isEmpty) {
        _playbackState = PlaybackState.stopped;
        _audioLoadingState = AudioLoadingState.error;
        _audioLoadingError = 'Album has no songs';
        notifyListeners();
        throw Exception('Album has no songs');
      }

      debugPrint('Playing album: ${album.name} with ${_playlist.length} songs');
      _currentIndex = 0;
      _confirmedIndex = 0;
      _lastCompletedSongId = null;
      _lastManualCompletedSongId = null;
      _indexChangeLog.clear();

      // Track playlist source for persistence
      _playlistSource = 'album';
      _sourceId = album.id;

      await _playSongAtIndex(0);

      // Save state after setting up new playlist
      await _saveCurrentState();
    } catch (e) {
      debugPrint('Error playing album: $e');
      _playbackState = PlaybackState.stopped;
      _audioLoadingState = AudioLoadingState.error;
      _audioLoadingError = 'Failed to play album: ${e.toString()}';
      notifyListeners();
      throw Exception('Failed to play album: ${e.toString()}');
    }
  }

  Future<void> playRandomSongs([int count = 50]) async {
    try {
      _playbackState = PlaybackState.loading;
      _audioLoadingState = AudioLoadingState.loadingRandomSongs;
      _audioLoadingError = null;
      notifyListeners();

      _playlist = await _api.getRandomSongs(count);

      if (_playlist.isEmpty) {
        _playbackState = PlaybackState.stopped;
        _audioLoadingState = AudioLoadingState.error;
        _audioLoadingError = 'No random songs available';
        notifyListeners();
        throw Exception('No random songs available');
      }

      debugPrint('Playing random songs: ${_playlist.length} songs loaded');
      _currentIndex = 0;
      _confirmedIndex = 0;
      _lastCompletedSongId = null;
      _lastManualCompletedSongId = null;
      _indexChangeLog.clear();

      // Track playlist source for persistence
      _playlistSource = 'random';
      _sourceId = count.toString();

      await _playSongAtIndex(0);

      // Save state after setting up new playlist
      await _saveCurrentState();
    } catch (e) {
      debugPrint('Error playing random songs: $e');
      _playbackState = PlaybackState.stopped;
      _audioLoadingState = AudioLoadingState.error;
      _audioLoadingError = 'Failed to play random songs: ${e.toString()}';
      notifyListeners();
      throw Exception('Failed to play random songs: ${e.toString()}');
    }
  }

  Future<void> playSong(Song song) async {
    _audioLoadingState = AudioLoadingState.loadingSong;
    _audioLoadingError = null;
    notifyListeners();

    _playlist = [song];
    _currentIndex = 0;
    _confirmedIndex = 0;
    _lastCompletedSongId = null;
    _lastManualCompletedSongId = null;
    _indexChangeLog.clear();
    await _playSongAtIndex(0);
  }

  /// Starts playback without waiting for it to finish. just_audio's play()
  /// future completes only once playback is paused, stopped or completed.
  void _startPlayback() {
    unawaited(_audioPlayer.play().catchError((Object e) {
      debugPrint('[audio_player] Playback error: $e');
    }));
  }

  /// Runs [change] to the player's sequence after earlier changes finished,
  /// so a queued next track can't land in a sequence that was just replaced.
  Future<T> _changeSources<T>(Future<T> Function() change) {
    final result = _sourceChange.then((_) => change());
    _sourceChange = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Sets the player's source to [song], from the disk cache when available,
  /// starting at [initialPosition]. Returns the song's stream URL.
  Future<String> _loadSource(Song song, Duration initialPosition) {
    // Replacing the sequence drops a queued next track. Cleared right away,
    // not once the load runs, so a transition to the old queued track in the
    // meantime isn't taken for the next track of the new position.
    _queuedNextIndex = null;
    _pendingLoads++;
    return _changeSources(() async {
      final streamUrl = _api.getStreamUrl(song.id);
      final cachedFile = _audioCache.getCachedFile(song.id);
      if (cachedFile != null) {
        debugPrint('Playing from audio cache: ${song.title}');
        await _audioPlayer.setFilePath(cachedFile.path,
            initialPosition: initialPosition);
      } else {
        debugPrint('Streaming from network: ${song.title}');
        await _audioPlayer.setUrl(streamUrl, initialPosition: initialPosition);
      }
      return streamUrl;
    }).whenComplete(() => _pendingLoads--);
  }

  /// Appends the next track to the player's sequence if it's cached, so the
  /// player moves on to it without a gap. Streams aren't queued: if the
  /// network dropped, the player would fail at the transition, while the
  /// regular advance in [_onSongComplete] can skip ahead to a cached track.
  Future<void> _queueNextTrack() => _changeSources(() async {
        if (_disposed || _pendingLoads > 0 || _queuedNextIndex != null) {
          return;
        }
        if (_audioPlayer.sequence.length != 1) return;
        final nextIndex = _currentIndex + 1;
        if (nextIndex >= _playlist.length) return;
        final file = _audioCache.getCachedFile(_playlist[nextIndex].id);
        if (file == null) return;

        // Set before adding, in case the player reaches the end of the
        // current track while the source is being added
        _queuedNextIndex = nextIndex;
        try {
          await _audioPlayer.addAudioSource(AudioSource.file(file.path));
          debugPrint(
              '[gapless] Queued index $nextIndex: ${_playlist[nextIndex].title}');
        } catch (e) {
          debugPrint('[gapless] Could not queue index $nextIndex: $e');
          _queuedNextIndex = null;
        }
      });

  /// The player moved on to the queued next track by itself.
  Future<void> _onGaplessTransition() async {
    final nextIndex = _queuedNextIndex!;
    _queuedNextIndex = null;
    _logIndexChange('gapless', _currentIndex, nextIndex, 'player advanced');

    // The previous track played to the end
    _scrobbleCurrentSong();
    _lastCompletedSongId = _currentSong?.id;

    _currentIndex = nextIndex;
    _confirmedIndex = nextIndex;
    _currentSong = _playlist[nextIndex];
    _currentSongStartTime = DateTime.now();
    _currentSongScrobbled = false;
    _recentPositions.clear();
    notifyListeners();

    try {
      // The player's volume applies to the whole sequence, so the new track's
      // gain takes effect just after the transition
      await _readReplayGainAndApplyVolume(_api.getStreamUrl(_currentSong!.id),
          cachedFile: _audioCache.getCachedFile(_currentSong!.id));
      _scrobbleQueue.queueNowPlaying(_currentSong!.id);

      // Drop the finished track so the sequence is [current] again
      await _changeSources(() async {
        if (_audioPlayer.currentIndex == 1 &&
            _audioPlayer.sequence.length == 2) {
          await _audioPlayer.removeAudioSourceAt(0);
        }
      });
      _preloadUpcomingSongs();
      unawaited(_queueNextTrack());
      await _saveCurrentState();
    } catch (e) {
      debugPrint('[gapless] Error after transition to index $nextIndex: $e');
    }
  }

  Future<void> _playSongAtIndex(int index,
      {Duration initialPosition = Duration.zero}) async {
    if (index < 0 || index >= _playlist.length) {
      debugPrint(
          '[play_song] Invalid index $index (playlist length: ${_playlist.length})');
      return;
    }

    final previousIndex = _currentIndex;
    debugPrint(
        '[play_song] Starting playback for index $index: ${_playlist[index].title}');
    _logIndexChange(
        '_playSongAtIndex', previousIndex, index, 'song loading started');

    _currentIndex = index;
    _currentSong = _playlist[index];
    _playbackState = PlaybackState.loading;

    notifyListeners();

    try {
      // Record when this song started playing and clear position tracking
      _currentSongStartTime = DateTime.now();
      _recentPositions.clear();
      // A resumed song past the threshold was scrobbled in its earlier session
      _currentSongScrobbled = initialPosition > Duration.zero &&
          _hasReachedScrobbleThreshold(
              initialPosition, Duration(seconds: _currentSong!.duration ?? 0));

      final streamUrl = await _loadSource(_currentSong!, initialPosition);
      final cachedFile = _audioCache.getCachedFile(_currentSong!.id);
      _needsSourceReload = false;

      // Apply ReplayGain volume adjustment BEFORE starting playback
      // If ReplayGain data is already available (from preloading), apply it immediately
      // Otherwise, read the metadata and apply it
      await _readReplayGainAndApplyVolume(streamUrl, cachedFile: cachedFile);

      // just_audio's play() future only completes when playback is paused,
      // stopped or completed, so it must not be awaited here.
      _startPlayback();

      // Song successfully started, reset loading state
      _audioLoadingState = AudioLoadingState.idle;
      _audioLoadingError = null;

      // Send now playing notification to server (queued for reliability)
      _scrobbleQueue.queueNowPlaying(_currentSong!.id);

      // Download upcoming songs to the disk cache (up to 3 tracks ahead)
      _preloadUpcomingSongs();
      unawaited(_queueNextTrack());

      // Mark this index as confirmed now that the song actually started
      _confirmedIndex = _currentIndex;
      _logIndexChange('_playSongAtIndex', _currentIndex, _currentIndex,
          'song playback confirmed');

      debugPrint(
          '[play_song] Successfully started: ${_currentSong!.title} (confirmed index: $_confirmedIndex)');
    } catch (e) {
      debugPrint('[play_song] Error playing song at index $index: $e');
      _playbackState = PlaybackState.stopped;
      _audioLoadingState = AudioLoadingState.error;
      _audioLoadingError = 'Failed to play song: $e';

      notifyListeners();
      throw Exception('Failed to play song: $e');
    }
  }

  Future<void> play() async {
    debugPrint(
        '[audio_player] Play requested - currentSong: ${_currentSong?.title}, state: $_playbackState');

    if (_currentSong == null && _playlist.isNotEmpty) {
      debugPrint(
          '[audio_player] No current song, starting playlist at index $_currentIndex');
      await _playSongAtIndex(_currentIndex);
    } else if (_currentSong != null && _needsSourceReload) {
      debugPrint(
          '[audio_player] Reloading restored song: ${_currentSong!.title}');
      try {
        await _playSongAtIndex(_currentIndex,
            initialPosition: _pendingResumePosition);
      } catch (e) {
        debugPrint('[audio_player] Reload failed: $e');
      }
    } else if (_currentSong != null) {
      debugPrint(
          '[audio_player] Resuming current song: ${_currentSong!.title}');
      if (_currentSongStartTime == null) {
        // First play of a song restored from a previous session: it wasn't
        // started through _playSongAtIndex, so mark it as playing now.
        _currentSongStartTime = DateTime.now();
        _scrobbleQueue.queueNowPlaying(_currentSong!.id);
      }
      _startPlayback();
    } else {
      debugPrint(
          '[audio_player] Cannot play - no current song and empty playlist');
    }
  }

  Future<void> pause() async {
    debugPrint(
        '[audio_player] Pause requested - currentSong: ${_currentSong?.title}, state: $_playbackState');
    await _audioPlayer.pause();
  }

  Future<void> stop() async {
    await _audioPlayer.stop();
    _currentPosition = Duration.zero;
    _totalDuration = Duration.zero;
    _playbackState = PlaybackState.stopped;
    notifyListeners();
  }

  bool _canSkip() {
    final now = DateTime.now();
    final timeSinceLastSkip = _lastSkipTime == null
        ? null
        : now.difference(_lastSkipTime!).inMilliseconds;

    if (_lastSkipTime == null || timeSinceLastSkip! > _skipDebounceMs) {
      _lastSkipTime = now;
      return true;
    }

    return false;
  }

  Future<void> next() async {
    const source = 'manual_next';
    final currentIdx = _currentIndex;
    final targetIdx = currentIdx + 1;

    debugPrint(
        '[$source] Skip next requested - current: ${_currentSong?.title}, index: $currentIdx -> $targetIdx');
    _logIndexChange(source, currentIdx, targetIdx, 'skip next requested');

    if (!_canSkip()) {
      debugPrint('[$source] Skip blocked by debounce');
      return;
    }

    if (_skipOperationInProgress) {
      debugPrint(
          '[$source] Skip blocked - operation already in progress (source: $_lastSkipSource)');
      _printIndexChangeLog();
      return;
    }

    if (targetIdx >= _playlist.length) {
      debugPrint(
          '[$source] No next track available (target: $targetIdx, playlist: ${_playlist.length})');
      return;
    }

    // Check for unexpected index jumps
    final indexDiff = targetIdx - _confirmedIndex;
    if (indexDiff > 2) {
      debugPrint(
          '[$source] WARNING: Large index jump detected! confirmed: $_confirmedIndex, target: $targetIdx');
      _printIndexChangeLog();
    }

    // Mark operation in progress immediately
    _skipOperationInProgress = true;
    _lastSkipSource = source;
    debugPrint('[$source] Starting skip operation to index $targetIdx');

    try {
      // Scrobble current song if it has been played enough
      _scrobbleCurrentSongIfEligible();

      // Move directly to target track - let _playSongAtIndex handle the stop/start
      await _playSongAtIndexOrNextCached(targetIdx);
      debugPrint('[$source] Successfully advanced to track $_currentIndex');
    } catch (e) {
      debugPrint('[$source] Error during skip: $e');
      _printIndexChangeLog();
    } finally {
      _skipOperationInProgress = false;
      _lastSkipSource = null;
      debugPrint('[$source] Skip operation completed');

      // Save state after track change
      await _saveCurrentState();
    }
  }

  Future<void> previous() async {
    const source = 'manual_previous';
    debugPrint(
        '[$source] Skip previous requested - current: ${_currentSong?.title}, index: $_currentIndex');

    if (!_canSkip()) {
      debugPrint('[$source] Skip blocked by debounce');
      return;
    }

    if (_skipOperationInProgress) {
      debugPrint(
          '[$source] Skip blocked - operation already in progress (source: $_lastSkipSource)');
      return;
    }

    if (!hasPrevious) {
      debugPrint('[$source] No previous track available');
      return;
    }

    // Mark operation in progress immediately
    _skipOperationInProgress = true;
    _lastSkipSource = source;
    debugPrint('[$source] Starting skip operation');

    try {
      // Scrobble current song if it has been played enough
      _scrobbleCurrentSongIfEligible();

      // Move directly to previous track - let _playSongAtIndex handle the stop/start
      await _playSongAtIndex(_currentIndex - 1);
      debugPrint('[$source] Successfully moved to track ${_currentIndex - 1}');
    } catch (e) {
      debugPrint('[$source] Error during skip: $e');
    } finally {
      _skipOperationInProgress = false;
      _lastSkipSource = null;
      debugPrint('[$source] Skip operation completed');

      // Save state after track change
      await _saveCurrentState();
    }
  }

  Future<void> seekTo(Duration position) async {
    await _audioPlayer.seek(position);
  }

  /// Tracks position updates with timestamps for stuck playhead detection.
  /// Maintains a sliding window of recent position updates to analyze movement patterns.
  void _trackPositionUpdate(Duration position) {
    final now = DateTime.now();
    _recentPositions.add(_PositionUpdate(position, now));

    // Keep only the last N position updates to avoid memory growth
    if (_recentPositions.length > _maxPositionHistorySize) {
      _recentPositions.removeAt(0);
    }
  }

  /// Checks if the playhead appears to be stuck (not moving) in the last seconds of a song.
  /// This addresses cases where just_audio completion events fail due to network buffering,
  /// streaming interruptions, or codec timing issues that cause songs to hang near the end.
  ///
  /// Returns true if:
  /// - We're in the near-end zone (last 2 seconds of song)
  /// - Position hasn't moved significantly over the past 1+ seconds
  /// - Player should be playing (not paused by user)
  bool _isPlayheadStuck(Duration currentPosition) {
    // Need at least 3 position updates to detect stuckness
    if (_recentPositions.length < 3) return false;

    // Check if we're in the near-end zone (last 2 seconds)
    final remainingTime = _totalDuration - currentPosition;
    if (remainingTime > _nearEndThreshold) return false;

    final now = DateTime.now();

    // Look for position updates in the last 2 seconds
    final recentUpdates = _recentPositions.where((update) {
      final age = now.difference(update.timestamp).inMilliseconds;
      return age <= _stuckPositionTimeoutMs;
    }).toList();

    if (recentUpdates.length < 2) return false;

    // Check if position hasn't changed significantly in recent updates
    final oldestRecent = recentUpdates.first;
    final newestRecent = recentUpdates.last;

    final positionChange = newestRecent.position - oldestRecent.position;
    final timeSpan = newestRecent.timestamp.difference(oldestRecent.timestamp);

    // If position moved less than minimum expected over a sufficient time period, consider it stuck
    final isStuck = positionChange < _minPositionMovement &&
        timeSpan.inMilliseconds > _minStuckDurationMs;

    if (isStuck) {
      debugPrint(
          '[stuck_detection] Playhead appears stuck - position change: ${positionChange.inMilliseconds}ms over ${timeSpan.inMilliseconds}ms');
    }

    return isStuck;
  }

  /// Checks if we should trigger completion when playback stops near the end.
  /// This handles cases where the position stream stops updating before the
  /// completion event fires, causing playback to get stuck.
  void _checkCompletionOnStop() {
    // Only check if we have a current song, valid duration, and aren't already handling a skip
    if (_currentSong == null ||
        _totalDuration == Duration.zero ||
        _skipOperationInProgress) {
      return;
    }

    // Prevent duplicate completions for the same song
    if (_lastManualCompletedSongId == _currentSong!.id) {
      return;
    }

    // Get current position from the player
    final currentPosition = _currentPosition;
    final remainingTime = _totalDuration - currentPosition;

    // If we're within 2 seconds of the end, consider this a completion
    // (generous threshold to catch cases where playback stopped slightly before the actual end)
    const stoppedNearEndThreshold = Duration(seconds: 2);

    if (remainingTime <= stoppedNearEndThreshold &&
        remainingTime >= Duration.zero) {
      debugPrint(
          '[stop_completion] Playback stopped near end - position: ${currentPosition.inSeconds}s, duration: ${_totalDuration.inSeconds}s, remaining: ${remainingTime.inSeconds}s');

      // Verify the completion event hasn't fired
      if (_audioPlayer.playerState.processingState !=
              ProcessingState.completed &&
          _lastCompletedSongId != _currentSong!.id) {
        debugPrint(
            '[stop_completion] Triggering completion - playback stopped ${remainingTime.inMilliseconds}ms from end');
        _lastManualCompletedSongId = _currentSong!.id;
        _onSongComplete();
      }
    }
  }

  /// Manual completion detection as fallback for when just_audio doesn't fire completion
  void _checkManualCompletion(Duration position) {
    // Only check if we have a current song, valid duration, and player is actually playing
    if (_currentSong == null ||
        _totalDuration == Duration.zero ||
        !_audioPlayer.playerState.playing ||
        _skipOperationInProgress) {
      return;
    }

    // Prevent duplicate manual completions for the same song
    if (_lastManualCompletedSongId == _currentSong!.id) {
      return;
    }

    // Enhanced completion detection with dual fallback mechanisms:
    // Method 1: Traditional close-to-end detection (within 500ms of song end)
    //   - Reliable for normal playback completion
    //   - Handles cases where just_audio completion fires late
    //
    // Method 2: Stuck playhead detection (position not advancing in near-end zone)
    //   - Catches streaming/buffering issues that freeze playhead
    //   - Prevents songs from hanging indefinitely in final seconds
    //   - Only active in last 2 seconds to avoid false positives

    final remainingTime = _totalDuration - position;
    const completionTolerance = Duration(milliseconds: 500);

    bool shouldTriggerCompletion = false;
    String completionReason = '';

    // Method 1: Traditional close-to-end detection. Skipped when the next
    // track is queued in the player, which then moves on by itself.
    if (_queuedNextIndex == null &&
        remainingTime <= completionTolerance &&
        remainingTime >= Duration.zero) {
      shouldTriggerCompletion = true;
      completionReason =
          'close to end (${remainingTime.inMilliseconds}ms remaining)';
    }
    // Method 2: Stuck playhead detection
    else if (_isPlayheadStuck(position)) {
      shouldTriggerCompletion = true;
      completionReason = 'stuck playhead detected in near-end zone';
    }

    if (shouldTriggerCompletion) {
      debugPrint(
          '[manual_completion] Song appears complete - position: ${position.inSeconds}s, duration: ${_totalDuration.inSeconds}s, reason: $completionReason');

      // Check if just_audio completion hasn't fired yet and we haven't already completed this song
      if (_audioPlayer.playerState.processingState !=
              ProcessingState.completed &&
          _lastCompletedSongId != _currentSong!.id) {
        debugPrint(
            '[manual_completion] just_audio completion not detected, triggering manual completion ($completionReason)');
        _lastManualCompletedSongId = _currentSong!.id;
        _onSongComplete();
      }
    }
  }

  void _onSongComplete() {
    const source = 'auto_complete';
    final currentSongId = _currentSong?.id;
    final currentIdx =
        _confirmedIndex; // Use confirmed index, not _currentIndex
    final targetIdx = currentIdx + 1;

    debugPrint(
        '[$source] Song completed: ${_currentSong?.title}, confirmed: $currentIdx, current: $_currentIndex, songId: $currentSongId');

    // Prevent duplicate completion handling for the same song
    if (_lastCompletedSongId == currentSongId && currentSongId != null) {
      debugPrint(
          '[$source] Ignoring duplicate completion event for song: $currentSongId');
      return;
    }

    _lastCompletedSongId = currentSongId;
    _logIndexChange(source, currentIdx, targetIdx, 'song completion detected');

    // Send scrobble submission for the completed song
    _scrobbleCurrentSong();

    // Prevent auto-advance if a skip operation is already in progress
    if (_skipOperationInProgress) {
      debugPrint(
          '[$source] Auto-advance blocked - skip operation in progress (source: $_lastSkipSource)');
      _printIndexChangeLog();
      return;
    }

    // Check if we have a next track using confirmed index
    if (targetIdx >= _playlist.length) {
      debugPrint(
          '[$source] End of playlist reached (target: $targetIdx, playlist: ${_playlist.length})');
      _playbackState = PlaybackState.stopped;
      notifyListeners();
      return;
    }

    debugPrint(
        '[$source] Auto-advancing from confirmed index $currentIdx to $targetIdx');

    // Use async helper to ensure _skipOperationInProgress is always reset
    _autoAdvanceToNext(targetIdx, source);
  }

  /// Async helper method for auto-advance with proper error handling.
  /// Uses try-finally to ensure _skipOperationInProgress is always reset.
  Future<void> _autoAdvanceToNext(int targetIdx, String source) async {
    _skipOperationInProgress = true;
    _lastSkipSource = source;

    try {
      await _playSongAtIndexOrNextCached(targetIdx);
      debugPrint('[$source] Auto-advance completed to index $_currentIndex');
    } catch (e) {
      debugPrint('[$source] Auto-advance failed: $e');
      _printIndexChangeLog();

      // Critical fix: Reset playback state on error to prevent stuck loading state
      _playbackState = PlaybackState.stopped;
      _audioLoadingState = AudioLoadingState.idle;
      _audioLoadingError = 'Failed to advance: $e';
    } finally {
      _skipOperationInProgress = false;
      _lastSkipSource = null;
      notifyListeners(); // Trigger UI rebuild to reset loading state
    }
  }

  void _scrobbleCurrentSong() {
    if (_currentSong != null &&
        _currentSongStartTime != null &&
        !_currentSongScrobbled) {
      // Send scrobble submission with the timestamp when the song started playing (queued for reliability)
      _scrobbleQueue.queueSubmission(_currentSong!.id,
          playedAt: _currentSongStartTime!);

      // Mark this play as scrobbled to prevent duplicate scrobbles
      _currentSongScrobbled = true;
    }
  }

  /// Checks if the current song should be scrobbled based on progress.
  /// A song should be scrobbled if it has been played to the configured
  /// percentage threshold or the configured minimum play time, whichever
  /// comes first (see [SettingsService.scrobbleMinPlayTimeMinutes] and
  /// [SettingsService.scrobbleThresholdPercent]).
  bool _shouldScrobbleCurrentSong() {
    if (_currentSong == null || _currentSongStartTime == null) return false;

    // Don't scrobble if already scrobbled
    if (_currentSongScrobbled) return false;

    return _hasReachedScrobbleThreshold(_currentPosition, _totalDuration);
  }

  bool _hasReachedScrobbleThreshold(
      Duration playedDuration, Duration songDuration) {
    final minPlayTime = Duration(
        milliseconds:
            (_settingsService.scrobbleMinPlayTimeMinutes * 60000).round());

    // Check if we've played for at least the configured minimum play time
    if (playedDuration >= minPlayTime) {
      return true;
    }

    // Check if we've played for at least the configured percentage of the song
    final thresholdFraction = _settingsService.scrobbleThresholdPercent / 100;
    if (songDuration.inSeconds > 0 &&
        playedDuration.inSeconds >=
            songDuration.inSeconds * thresholdFraction) {
      return true;
    }

    return false;
  }

  void _scrobbleCurrentSongIfEligible() {
    if (_shouldScrobbleCurrentSong()) {
      _scrobbleCurrentSong();
    }
  }

  String formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// Logs to both the console (debug builds) and the persistent ReplayGain
  /// debug log (only when the user has enabled it in Settings).
  void _rgLog(String message) {
    debugPrint(message);
    ReplayGainDebugLogger.instance.log(message);
  }

  Future<void> _readReplayGainAndApplyVolume(String streamUrl,
      {File? cachedFile}) async {
    if (_currentSong == null) return;

    _rgLog(
        '[ReplayGain] Processing song: "${_currentSong!.title}" by "${_currentSong!.artist}" '
        '(id=${_currentSong!.id}, album="${_currentSong!.album}", format=${_currentSong!.suffix}/${_currentSong!.contentType})');
    _rgLog(
        '[ReplayGain] Stream URL: ${ReplayGainDebugLogger.redact(streamUrl)}');
    _rgLog('[ReplayGain] Initial RG values from API/cache:');
    _rgLog(
        '[ReplayGain]   TrackGain: ${_currentSong!.replayGainTrackGain?.toStringAsFixed(2) ?? "null"}');
    _rgLog(
        '[ReplayGain]   AlbumGain: ${_currentSong!.replayGainAlbumGain?.toStringAsFixed(2) ?? "null"}');

    // Apply volume immediately if we already have ReplayGain data (from preloading)
    if (_currentSong!.replayGainTrackGain != null ||
        _currentSong!.replayGainAlbumGain != null) {
      _rgLog(
          '[ReplayGain] Using preloaded ReplayGain data for immediate volume adjustment');
      _applyReplayGainVolume();
      return;
    }

    _rgLog('[ReplayGain] No ReplayGain in API response, reading from file...');

    try {
      // Read ReplayGain metadata directly from the audio file
      final replayGainData = cachedFile != null
          ? await ReplayGainReader.readFromFile(cachedFile)
          : await ReplayGainReader.readFromUrl(streamUrl);

      _rgLog('[ReplayGain] File reading complete:');
      _rgLog(
          '[ReplayGain]   TrackGain: ${replayGainData.trackGain?.toStringAsFixed(2) ?? "null"}');
      _rgLog(
          '[ReplayGain]   AlbumGain: ${replayGainData.albumGain?.toStringAsFixed(2) ?? "null"}');
      _rgLog(
          '[ReplayGain]   TrackPeak: ${replayGainData.trackPeak?.toStringAsFixed(4) ?? "null"}');
      _rgLog(
          '[ReplayGain]   AlbumPeak: ${replayGainData.albumPeak?.toStringAsFixed(4) ?? "null"}');
      _rgLog('[ReplayGain]   Has any data: ${replayGainData.hasAnyData}');

      // Update the current song with the read metadata WITHOUT triggering UI updates
      // We only update the ReplayGain fields, keeping everything else identical
      final updatedSong = Song(
        id: _currentSong!.id,
        title: _currentSong!.title,
        artist: _currentSong!.artist,
        album: _currentSong!.album,
        albumId: _currentSong!.albumId,
        coverArt: _currentSong!.coverArt,
        duration: _currentSong!.duration,
        track: _currentSong!.track,
        contentType: _currentSong!.contentType,
        suffix: _currentSong!.suffix,
        replayGainTrackGain: replayGainData.trackGain,
        replayGainAlbumGain: replayGainData.albumGain,
        replayGainTrackPeak: replayGainData.trackPeak,
        replayGainAlbumPeak: replayGainData.albumPeak,
      );

      // Only update if the new song is actually different (this should be true due to ReplayGain data)
      if (updatedSong != _currentSong) {
        _rgLog('[ReplayGain] Updating song object with new RG data');
        // Update the internal reference without notifying listeners
        _currentSong = updatedSong;

        // Also update the playlist to keep consistency
        if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
          _playlist[_currentIndex] = updatedSong;
        }
      } else {
        _rgLog('[ReplayGain] Song unchanged (no new RG data found in file)');
      }

      // Apply the volume adjustment (this doesn't trigger UI updates)
      _applyReplayGainVolume();
    } catch (e, stackTrace) {
      _rgLog('[ReplayGain] ERROR reading ReplayGain metadata: $e');
      _rgLog('[ReplayGain] Stack trace: $stackTrace');
      // Fall back to applying volume without metadata
      _applyReplayGainVolume();
    }
  }

  void _applyReplayGainVolume() {
    if (_currentSong == null) return;

    final trackGain = _currentSong!.replayGainTrackGain;
    final albumGain = _currentSong!.replayGainAlbumGain;
    final trackPeak = _currentSong!.replayGainTrackPeak;
    final albumPeak = _currentSong!.replayGainAlbumPeak;

    final volumeMultiplier = _settingsService.calculateVolumeAdjustment(
      trackGain: trackGain,
      albumGain: albumGain,
      trackPeak: trackPeak,
      albumPeak: albumPeak,
    );

    _audioPlayer.setVolume(volumeMultiplier);

    // Enhanced debug output to show ReplayGain metadata status
    final hasTrackGain = trackGain != null;
    final hasAlbumGain = albumGain != null;
    final rgMode = _settingsService.replayGainMode.toString().split('.').last;

    _rgLog('');
    _rgLog('='.padRight(80, '='));
    _rgLog('[ReplayGain] VOLUME APPLIED');
    _rgLog('='.padRight(80, '='));
    _rgLog(
        '[ReplayGain] Song: "${_currentSong!.title}" by "${_currentSong!.artist}" (id=${_currentSong!.id})');
    _rgLog(
        '[ReplayGain] Stream URL: ${ReplayGainDebugLogger.redact(_api.getStreamUrl(_currentSong!.id))}');
    _rgLog('[ReplayGain] Mode: $rgMode');
    _rgLog(
        '[ReplayGain] TrackGain: ${trackGain?.toStringAsFixed(2) ?? 'null'} dB');
    _rgLog(
        '[ReplayGain] AlbumGain: ${albumGain?.toStringAsFixed(2) ?? 'null'} dB');
    _rgLog(
        '[ReplayGain] TrackPeak: ${trackPeak?.toStringAsFixed(4) ?? 'null'}');
    _rgLog(
        '[ReplayGain] AlbumPeak: ${albumPeak?.toStringAsFixed(4) ?? 'null'}');
    _rgLog(
        '[ReplayGain] Preamp: ${_settingsService.replayGainPreamp.toStringAsFixed(1)} dB');
    _rgLog(
        '[ReplayGain] Fallback: ${_settingsService.replayGainFallbackGain.toStringAsFixed(1)} dB');
    _rgLog(
        '[ReplayGain] Prevent Clipping: ${_settingsService.replayGainPreventClipping}');
    _rgLog(
        '[ReplayGain] Source: ${hasTrackGain || hasAlbumGain ? 'METADATA' : 'FALLBACK'}');
    _rgLog(
        '[ReplayGain] Final Volume Multiplier: ${volumeMultiplier.toStringAsFixed(6)} (${(volumeMultiplier * 100).toStringAsFixed(2)}%)');
    _rgLog('='.padRight(80, '='));
    _rgLog('');
  }

  Future<void> refreshReplayGainVolume() async {
    _applyReplayGainVolume();
  }

  /// Plays the song at [index]. If it can't be loaded (e.g. the network is
  /// down) and isn't cached, skips forward to the next song that is cached
  /// so playback can continue offline.
  Future<void> _playSongAtIndexOrNextCached(int index) async {
    try {
      await _playSongAtIndex(index);
    } catch (e) {
      final playlist = _playlist;
      for (var i = index + 1; i < playlist.length; i++) {
        if (!_audioCache.isCached(playlist[i].id)) continue;
        debugPrint(
            '[offline] Could not load index $index, skipping to cached index $i');
        await _playSongAtIndex(i);
        return;
      }
      rethrow;
    }
  }

  /// Downloads upcoming songs in the playlist to the disk cache so playback
  /// can continue if the network drops. Downloads run one at a time, nearest
  /// track first, so the next song is ready as early as possible.
  Future<void> _preloadUpcomingSongs() async {
    final playlist = _playlist;
    final start = _currentIndex + 1;
    final end = (start + _maxPreloadTracks).clamp(0, playlist.length);
    if (start >= end) return;

    _activePreloads++;
    if (_audioLoadingState == AudioLoadingState.idle) {
      _audioLoadingState = AudioLoadingState.preloading;
    }
    notifyListeners();

    try {
      for (var index = start; index < end; index++) {
        // Stop if the playlist was replaced while downloading
        if (_disposed || !identical(playlist, _playlist)) break;
        await _preloadSingleTrack(playlist, index);
        if (index == _currentIndex + 1) unawaited(_queueNextTrack());
      }
    } finally {
      _activePreloads--;
      if (_activePreloads == 0 &&
          _audioLoadingState == AudioLoadingState.preloading) {
        _audioLoadingState = AudioLoadingState.idle;
      }
      notifyListeners();
    }
  }

  /// Downloads the track at [index] and reads its ReplayGain metadata from
  /// the downloaded file if the server didn't provide it.
  Future<void> _preloadSingleTrack(List<Song> playlist, int index) async {
    final song = playlist[index];
    try {
      final file = await _audioCache.prefetch(
        song.id,
        _api.getStreamUrl(song.id),
        suffix: song.suffix,
      );
      if (file == null) return;

      if (song.replayGainTrackGain != null ||
          song.replayGainAlbumGain != null) {
        return;
      }

      final replayGainData = await ReplayGainReader.readFromFile(file);
      if (!replayGainData.hasAnyData) {
        _rgLog(
            '[ReplayGain] Preload found no ReplayGain data for "${song.title}" (id=${song.id})');
        return;
      }

      // Only update if the playlist entry is still the same song
      if (!identical(playlist, _playlist) ||
          index >= _playlist.length ||
          _playlist[index].id != song.id) {
        return;
      }
      _playlist[index] = Song(
        id: song.id,
        title: song.title,
        artist: song.artist,
        album: song.album,
        albumId: song.albumId,
        coverArt: song.coverArt,
        duration: song.duration,
        track: song.track,
        contentType: song.contentType,
        suffix: song.suffix,
        replayGainTrackGain: replayGainData.trackGain,
        replayGainAlbumGain: replayGainData.albumGain,
        replayGainTrackPeak: replayGainData.trackPeak,
        replayGainAlbumPeak: replayGainData.albumPeak,
      );
      _rgLog(
          '[ReplayGain] Preload loaded ReplayGain for "${song.title}": Track=${replayGainData.trackGain}, Album=${replayGainData.albumGain}');
    } catch (e) {
      debugPrint('Error preloading track $index (${song.title}): $e');
      // Don't rethrow - continue with other preloads
    }
  }

  /// Removes all downloaded audio from the disk cache.
  Future<void> clearAudioCache() => _audioCache.clear();

  /// Size of downloaded audio in the disk cache, in bytes.
  Future<int> audioCacheSize() => _audioCache.sizeInBytes();

  /// Starts the sleep timer with the specified duration
  void startSleepTimer(Duration duration) {
    // Cancel any existing timer
    _sleepTimer?.cancel();

    _sleepTimerDuration = duration;
    _sleepTimerStartTime = DateTime.now();
    _isSleepTimerActive = true;

    debugPrint('Sleep timer started for ${formatDuration(duration)}');

    // Start the timer
    _sleepTimer = Timer(duration, () {
      _onSleepTimerComplete();
    });

    notifyListeners();
  }

  /// Cancels the active sleep timer
  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerDuration = null;
    _sleepTimerStartTime = null;
    _isSleepTimerActive = false;

    debugPrint('Sleep timer canceled');
    notifyListeners();
  }

  /// Extends the sleep timer by the specified duration
  void extendSleepTimer(Duration extension) {
    if (!_isSleepTimerActive) return;

    final currentRemaining = sleepTimerRemaining;
    if (currentRemaining != null) {
      // Cancel current timer and start a new one with extended duration
      _sleepTimer?.cancel();

      final newDuration = currentRemaining + extension;
      _sleepTimerDuration = _sleepTimerDuration! + extension;

      debugPrint(
          'Sleep timer extended by ${formatDuration(extension)}, new remaining: ${formatDuration(newDuration)}');

      _sleepTimer = Timer(newDuration, () {
        _onSleepTimerComplete();
      });

      notifyListeners();
    }
  }

  /// Called when the sleep timer expires
  void _onSleepTimerComplete() {
    debugPrint('Sleep timer expired - pausing playback');

    // Pause the audio
    pause();

    // Reset timer state
    _sleepTimer = null;
    _sleepTimerDuration = null;
    _sleepTimerStartTime = null;
    _isSleepTimerActive = false;

    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playerCompleteSubscription?.cancel();
    _playerStateSubscription?.cancel();
    _currentIndexSubscription?.cancel();
    _sleepTimer?.cancel();
    if (_ownsAudioCache) _audioCache.dispose();
    _persistence?.dispose();
    _scrobbleQueue.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }
}
