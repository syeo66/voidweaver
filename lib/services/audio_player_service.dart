import 'dart:async';
import 'package:just_audio/just_audio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'subsonic_api.dart';
import 'settings_service.dart';
import 'replaygain_reader.dart';

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

class AudioPlayerService extends ChangeNotifier {
  final AudioPlayer _audioPlayer;
  final SubsonicApi _api;
  final SettingsService _settingsService;

  PlaybackState _playbackState = PlaybackState.stopped;
  List<Song> _playlist = [];
  int _currentIndex = 0;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  Song? _currentSong;

  // Skip debouncing and operation control
  DateTime? _lastSkipTime;
  static const _skipDebounceMs = 200;
  bool _skipOperationInProgress = false;
  String? _lastSkipSource;

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

  // Enhanced loading states
  AudioLoadingState _audioLoadingState = AudioLoadingState.idle;
  String? _audioLoadingError;

  // Preload state
  Song? _preloadedSong;
  bool _isPreloading = false;
  String? _preloadedStreamUrl;

  // Sleep timer state
  Timer? _sleepTimer;
  Duration? _sleepTimerDuration;
  DateTime? _sleepTimerStartTime;
  bool _isSleepTimerActive = false;

  AudioPlayerService(this._api, this._settingsService,
      {AudioPlayer? audioPlayer})
      : _audioPlayer = audioPlayer ?? AudioPlayer() {
    _initializePlayer();
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
  bool get isPreloading => _isPreloading;
  Song? get preloadedSong => _preloadedSong;

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

  Future<void> playAlbum(Album album) async {
    try {
      _playbackState = PlaybackState.loading;
      _audioLoadingState = AudioLoadingState.loadingAlbum;
      _audioLoadingError = null;
      notifyListeners();

      // Clear any existing preload since we're changing playlist
      _clearPreload();

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
      _indexChangeLog.clear();
      await _playSongAtIndex(0);
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

      // Clear any existing preload since we're changing playlist
      _clearPreload();

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
      _indexChangeLog.clear();
      await _playSongAtIndex(0);
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

    // Clear any existing preload since we're changing playlist
    _clearPreload();

    _playlist = [song];
    _currentIndex = 0;
    _confirmedIndex = 0;
    _lastCompletedSongId = null;
    _indexChangeLog.clear();
    await _playSongAtIndex(0);
  }

  Future<void> _playSongAtIndex(int index) async {
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
      String streamUrl;

      // Check if this song is already preloaded
      if (_preloadedSong?.id == _currentSong!.id &&
          _preloadedStreamUrl != null) {
        debugPrint('Using preloaded URL for song: ${_currentSong!.title}');
        streamUrl = _preloadedStreamUrl!;

        // Clear preload state since we're using it now
        _preloadedSong = null;
        _preloadedStreamUrl = null;
      } else {
        streamUrl = _api.getStreamUrl(_currentSong!.id);
        debugPrint('Playing song: ${_currentSong!.title} from URL: $streamUrl');
      }

      // Record when this song started playing
      _currentSongStartTime = DateTime.now();

      await _audioPlayer.setUrl(streamUrl);
      await _audioPlayer.play();

      // Song successfully started, reset loading state
      _audioLoadingState = AudioLoadingState.idle;
      _audioLoadingError = null;

      // Send now playing notification to server
      _api.scrobbleNowPlaying(_currentSong!.id);

      // Read ReplayGain metadata from the audio file and apply volume adjustment
      _readReplayGainAndApplyVolume(streamUrl);

      // Preload next song if available
      _preloadNextSong();

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
    } else if (_currentSong != null) {
      debugPrint(
          '[audio_player] Resuming current song: ${_currentSong!.title}');
      await _audioPlayer.play();
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
      await _playSongAtIndex(targetIdx);
      debugPrint('[$source] Successfully advanced to track $targetIdx');
    } catch (e) {
      debugPrint('[$source] Error during skip: $e');
      _printIndexChangeLog();
    } finally {
      _skipOperationInProgress = false;
      _lastSkipSource = null;
      debugPrint('[$source] Skip operation completed');
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
    }
  }

  Future<void> seekTo(Duration position) async {
    await _audioPlayer.seek(position);
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
    _skipOperationInProgress = true;
    _lastSkipSource = source;

    _playSongAtIndex(targetIdx).then((_) {
      _skipOperationInProgress = false;
      _lastSkipSource = null;
      debugPrint('[$source] Auto-advance completed to index $targetIdx');
    }).catchError((e) {
      _skipOperationInProgress = false;
      _lastSkipSource = null;
      debugPrint('[$source] Auto-advance failed: $e');
      _printIndexChangeLog();
    });
  }

  void _scrobbleCurrentSong() {
    if (_currentSong != null && _currentSongStartTime != null) {
      // Send scrobble submission with the timestamp when the song started playing
      _api.scrobbleSubmission(_currentSong!.id,
          playedAt: _currentSongStartTime!);
    }
  }

  /// Checks if the current song should be scrobbled based on progress.
  /// A song should be scrobbled if it has been played for at least 30 seconds
  /// or 50% of its duration, whichever is shorter.
  bool _shouldScrobbleCurrentSong() {
    if (_currentSong == null || _currentSongStartTime == null) return false;

    final playedDuration = _currentPosition;
    final songDuration = _totalDuration;

    // Minimum play time is 30 seconds
    const minPlayTime = Duration(seconds: 30);

    // Check if we've played for at least 30 seconds
    if (playedDuration >= minPlayTime) {
      return true;
    }

    // Check if we've played for at least 50% of the song
    if (songDuration.inSeconds > 0 &&
        playedDuration.inSeconds >= songDuration.inSeconds * 0.5) {
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

  Future<void> _readReplayGainAndApplyVolume(String streamUrl) async {
    if (_currentSong == null) return;

    // Skip if we already have ReplayGain data to prevent duplicate processing
    if (_currentSong!.replayGainTrackGain != null ||
        _currentSong!.replayGainAlbumGain != null) {
      _applyReplayGainVolume();
      return;
    }

    try {
      // Read ReplayGain metadata directly from the audio file
      final replayGainData = await ReplayGainReader.readFromUrl(streamUrl);

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
        // Update the internal reference without notifying listeners
        _currentSong = updatedSong;

        // Also update the playlist to keep consistency
        if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
          _playlist[_currentIndex] = updatedSong;
        }
      }

      // Apply the volume adjustment (this doesn't trigger UI updates)
      _applyReplayGainVolume();
    } catch (e) {
      debugPrint('Error reading ReplayGain metadata: $e');
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

    debugPrint(
        'Applied ReplayGain volume: ${volumeMultiplier.toStringAsFixed(3)} for song: ${_currentSong!.title}');
    debugPrint(
        '  Mode: $rgMode, TrackGain: ${trackGain?.toStringAsFixed(2) ?? 'null'}, AlbumGain: ${albumGain?.toStringAsFixed(2) ?? 'null'}');
    debugPrint(
        '  Preamp: ${_settingsService.replayGainPreamp.toStringAsFixed(1)}dB, Fallback: ${_settingsService.replayGainFallbackGain.toStringAsFixed(1)}dB');
    debugPrint(
        '  Using ${hasTrackGain || hasAlbumGain ? 'metadata' : 'fallback'} gain');
  }

  Future<void> refreshReplayGainVolume() async {
    _applyReplayGainVolume();
  }

  /// Preloads the next song in the playlist for seamless playback
  Future<void> _preloadNextSong() async {
    if (!hasNext || _isPreloading) return;

    final nextIndex = _currentIndex + 1;
    final nextSong = _playlist[nextIndex];

    // Don't preload if it's already preloaded
    if (_preloadedSong?.id == nextSong.id) return;

    _isPreloading = true;
    _audioLoadingState = AudioLoadingState.preloading;
    notifyListeners();

    try {
      final streamUrl = _api.getStreamUrl(nextSong.id);
      debugPrint('Preloading next song: ${nextSong.title}');

      // Store the preloaded URL (this is instant, just generates the URL)
      _preloadedSong = nextSong;
      _preloadedStreamUrl = streamUrl;

      debugPrint('Successfully preloaded URL for: ${nextSong.title}');
    } catch (e) {
      debugPrint('Error preloading next song: $e');
      _preloadedSong = null;
      _preloadedStreamUrl = null;
    } finally {
      _isPreloading = false;
      // Only reset loading state if we're not in an error state
      if (_audioLoadingState == AudioLoadingState.preloading) {
        _audioLoadingState = AudioLoadingState.idle;
      }
      notifyListeners();
    }
  }

  /// Clears the preloaded song (called when playlist changes)
  void _clearPreload() {
    _preloadedSong = null;
    _preloadedStreamUrl = null;
    _isPreloading = false;
  }

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
  void dispose() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playerCompleteSubscription?.cancel();
    _playerStateSubscription?.cancel();
    _sleepTimer?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }
}
