import 'dart:async';
import 'dart:io';
import 'package:just_audio/just_audio.dart';
import 'package:flutter/foundation.dart';
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

/// Identifies an item in the player's sequence: the playlist position it
/// stands for, and the [AudioPlayerService._loadQueue] call that created it.
/// Set as each source's tag, so index events map back to songs even while
/// the sequence is being changed.
class _QueueEntry {
  final int generation;
  final int index;

  const _QueueEntry(this.generation, this.index);
}

/// Plays a playlist through just_audio. The whole playlist is handed to the
/// player as its sequence, so the player moves from track to track by itself
/// (gaplessly); the service follows its current index. See docs/PLAYBACK.md.
class AudioPlayerService extends ChangeNotifier {
  /// Upcoming tracks downloaded to the disk cache while playing
  static const int _maxPreloadTracks = 3;

  /// A downloaded next track isn't swapped into the sequence this close to
  /// the end of the current one, when the player may already be moving on to
  /// the streamed copy.
  static const Duration _swapCutoff = Duration(seconds: 10);

  static const _skipDebounceMs = 200;

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

  // Incremented whenever the player's sequence is replaced. Sources, preloads
  // and swaps from an older generation are ignored.
  int _generation = 0;
  // Playlist positions whose item in the player's sequence is a cached file
  final Set<int> _fileBacked = {};

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

  // Whether playback was stopped (or never started), as opposed to the player
  // being idle on the way to playing again, see isStopped
  bool _stopped = true;

  // Skips
  DateTime? _lastSkipTime;
  bool _skipOperationInProgress = false;

  // Set when a song couldn't be loaded (e.g. offline at startup); the queue
  // is loaded again on the next play()
  bool _needsSourceReload = false;
  Duration _pendingResumePosition = Duration.zero;

  // When the current play of the current song started; null for a song
  // restored from a previous session that hasn't been resumed yet
  DateTime? _currentSongStartTime;
  // Whether the current play of the current song has been scrobbled
  bool _currentSongScrobbled = false;

  // Sleep timer state
  Timer? _sleepTimer;
  Duration? _sleepTimerDuration;
  DateTime? _sleepTimerStartTime;
  bool _isSleepTimerActive = false;

  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _playerStateSubscription;
  StreamSubscription? _currentIndexSubscription;
  StreamSubscription? _errorSubscription;

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

  /// Whether a skip is being carried out; the UI disables the skip buttons.
  bool get isSkipOperationInProgress => _skipOperationInProgress;

  /// Whether playback was stopped. The player is also idle after a load error
  /// while the service continues elsewhere in the queue or reloads it; only
  /// this means the media session should end. See docs/PLAYBACK.md.
  bool get isStopped => _stopped;

  PlaybackState get playbackState => _playbackState;
  List<Song> get playlist => _playlist;
  int get currentIndex => _currentIndex;
  Duration get currentPosition => _currentPosition;
  Duration get totalDuration => _totalDuration;
  Song? get currentSong => _currentSong;
  bool get hasNext => _currentIndex < _playlist.length - 1;
  bool get hasPrevious => _currentIndex > 0;

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

  void _initializePlayer() {
    _positionSubscription = _audioPlayer.positionStream.listen((position) {
      _currentPosition = position;
      if (_playbackState == PlaybackState.playing) {
        _scrobbleCurrentSongIfEligible();
        _schedulePositionSave();
      }
      notifyListeners();
    });

    _durationSubscription = _audioPlayer.durationStream.listen((duration) {
      _totalDuration = duration ?? Duration.zero;
      notifyListeners();
    });

    _currentIndexSubscription =
        _audioPlayer.currentIndexStream.listen((_) => _followPlayer());

    _errorSubscription = _audioPlayer.errorStream.listen(_onPlayerError);

    _playerStateSubscription = _audioPlayer.playerStateStream.listen((state) {
      debugPrint('[audio_player] State changed to: $state');
      switch (state.processingState) {
        case ProcessingState.completed:
          _onQueueCompleted();
          return;
        case ProcessingState.idle:
          if (!state.playing) _playbackState = PlaybackState.stopped;
          break;
        case ProcessingState.loading:
        case ProcessingState.buffering:
          _playbackState = PlaybackState.loading;
          break;
        case ProcessingState.ready:
          // just_audio keeps `playing` true while buffering and on
          // completion, so ready + not playing is always a pause
          _playbackState =
              state.playing ? PlaybackState.playing : PlaybackState.paused;
          break;
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
      if (!savedState.hasValidIndex) return false;

      debugPrint(
          'Attempting to restore playlist with ${savedState.playlist.length} songs');

      _playlist = savedState.playlist;
      _playlistSource = savedState.playlistSource;
      _sourceId = savedState.sourceId;
      final resumeAt = savedState.currentPosition;

      // Load the queue but don't auto-play. If that fails (e.g. the server
      // is unreachable) keep the restored queue and retry on play().
      try {
        await _loadQueue(savedState.currentIndex,
            position: resumeAt, play: false);
      } catch (e) {
        debugPrint('Could not load restored song, will retry on play: $e');
        _needsSourceReload = true;
        _pendingResumePosition = resumeAt;
      }
      _currentPosition = resumeAt;
      _playbackState = PlaybackState.paused; // User must manually resume

      debugPrint(
          'Successfully restored playback state: ${_currentSong?.title} at $resumeAt');
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Failed to restore playback state: $e');
      // Clear invalid saved state
      await _persistence?.clearPlaybackState();
    }

    return false;
  }

  PersistedPlaybackState _persistedState() => PersistedPlaybackState(
        playlist: _playlist,
        currentIndex: _currentIndex,
        currentPosition: _currentPosition,
        isPlaying: _playbackState == PlaybackState.playing,
        lastUpdated: DateTime.now(),
        playlistSource: _playlistSource,
        sourceId: _sourceId,
      );

  Future<void> _saveCurrentState() async {
    if (_persistence == null || _playlist.isEmpty) return;
    await _persistence!.savePlaybackState(_persistedState());
  }

  void _schedulePositionSave() {
    if (_persistence == null || _playlist.isEmpty) return;
    _persistence!.schedulePositionSave(_persistedState());
  }

  Future<void> playAlbum(Album album) async {
    try {
      _playbackState = PlaybackState.loading;
      notifyListeners();

      var songs = album.songs;
      if (songs.isEmpty) {
        debugPrint(
            'Album ${album.name} has no songs, trying to fetch from API...');
        songs = (await _api.getAlbum(album.id)).songs;
      }
      if (songs.isEmpty) throw Exception('Album has no songs');

      debugPrint('Playing album: ${album.name} with ${songs.length} songs');
      _playlist = List.of(songs);
      _playlistSource = 'album';
      _sourceId = album.id;
      await _loadQueue(0);
    } catch (e) {
      _onLoadFailed('Failed to play album: $e');
      throw Exception('Failed to play album: $e');
    }
  }

  Future<void> playRandomSongs([int count = 50]) async {
    try {
      _playbackState = PlaybackState.loading;
      notifyListeners();

      final songs = await _api.getRandomSongs(count);
      if (songs.isEmpty) throw Exception('No random songs available');

      debugPrint('Playing random songs: ${songs.length} songs loaded');
      _playlist = List.of(songs);
      _playlistSource = 'random';
      _sourceId = count.toString();
      await _loadQueue(0);
    } catch (e) {
      _onLoadFailed('Failed to play random songs: $e');
      throw Exception('Failed to play random songs: $e');
    }
  }

  Future<void> playSong(Song song) async {
    _playlist = [song];
    try {
      await _loadQueue(0);
    } catch (e) {
      _onLoadFailed('Failed to play song: $e');
      throw Exception('Failed to play song: $e');
    }
  }

  void _onLoadFailed(String message) {
    debugPrint(message);
    // Otherwise the player stays idle with `playing` set, which the system
    // controls show as still loading
    if (_audioPlayer.playing) {
      unawaited(_audioPlayer.pause().catchError((Object _) {}));
    }
    _playbackState = PlaybackState.stopped;
    notifyListeners();
  }

  /// Starts playback without waiting for it to finish. just_audio's play()
  /// future completes only once playback is paused, stopped or completed.
  void _startPlayback() {
    unawaited(_audioPlayer.play().catchError((Object e) {
      debugPrint('[audio_player] Playback error: $e');
    }));
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

  AudioSource _sourceFor(int generation, int index, {File? file}) {
    final song = _playlist[index];
    final tag = _QueueEntry(generation, index);
    file ??= _audioCache.getCachedFile(song.id);
    return file != null
        ? AudioSource.file(file.path, tag: tag)
        : AudioSource.uri(Uri.parse(_api.getStreamUrl(song.id)), tag: tag);
  }

  /// Hands the whole playlist to the player, starting at [startIndex] and
  /// [position]. Downloaded tracks are played from the disk cache, the rest
  /// is streamed. If the start track can't be loaded and [play] is set,
  /// continues from the next downloaded track.
  Future<void> _loadQueue(int startIndex,
      {Duration position = Duration.zero, bool play = true}) async {
    final generation = ++_generation;
    _stopped = false;
    _fileBacked.clear();
    _awaitedIndex = null;
    final sources = [
      for (var i = 0; i < _playlist.length; i++) _sourceFor(generation, i)
    ];
    for (var i = 0; i < sources.length; i++) {
      if (sources[i] is UriAudioSource &&
          (sources[i] as UriAudioSource).uri.scheme == 'file') {
        _fileBacked.add(i);
      }
    }

    _setCurrentTrack(startIndex, position: position, playing: play);
    _playbackState = PlaybackState.loading;
    notifyListeners();
    // Before loading, so playback doesn't start at the previous track's gain
    await _loadReplayGain(startIndex);
    if (generation != _generation) return;

    try {
      await _playerOp(() async {
        if (generation != _generation) return;
        _settingSources = true;
        try {
          await _audioPlayer.setAudioSources(sources,
              initialIndex: startIndex, initialPosition: position);
        } finally {
          _settingSources = false;
        }
      });
    } on PlayerInterruptedException {
      // A newer _loadQueue() replaced the sequence
      return;
    } catch (e) {
      if (generation != _generation) return;
      final next = play ? _nextCachedIndex(startIndex) : null;
      if (next == null) rethrow;
      debugPrint(
          '[offline] Could not load index $startIndex, continuing at cached index $next');
      return _loadQueue(next);
    }
    if (generation != _generation) return;

    _needsSourceReload = false;
    if (play) {
      _startPlayback();
      _onTrackStarted();
    }
  }

  /// Moves playback to [index] within the current sequence.
  Future<void> _jumpTo(int index) async {
    // After stop() or an error the player has to load again
    if (_needsSourceReload ||
        _audioPlayer.processingState == ProcessingState.idle) {
      return _loadQueue(index);
    }

    final generation = _generation;
    // Inside the operation, so an index event for the old track arriving
    // meanwhile isn't taken for an advance from the new one
    await _playerOp(() async {
      if (generation != _generation) return;
      _setCurrentTrack(index, playing: true);
      // Before seeking, so the track doesn't start at the previous one's gain
      await _loadReplayGain(index);
      if (generation != _generation) return;
      _awaitedIndex = index;
      await _audioPlayer.seek(Duration.zero, index: index);
    });
    if (generation != _generation || _currentIndex != index) return;

    if (!_audioPlayer.playing) _startPlayback();
    _onTrackStarted();
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

    debugPrint('[audio_player] Player advanced to index ${entry.index}');
    // The previous track played to the end
    _scrobbleCurrentSong();
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

  void _setCurrentTrack(int index,
      {Duration position = Duration.zero, required bool playing}) {
    _currentIndex = index;
    _currentSong = _playlist[index];
    _currentPosition = position;
    // A restored song gets its start time once it's resumed, see play()
    _currentSongStartTime = playing ? DateTime.now() : null;
    // A song resumed past the threshold was scrobbled in its earlier session
    _currentSongScrobbled = position > Duration.zero &&
        _hasReachedScrobbleThreshold(
            position, Duration(seconds: _currentSong!.duration ?? 0));
    notifyListeners();
  }

  /// Bookkeeping once a track is playing.
  void _onTrackStarted() {
    _scrobbleQueue.queueNowPlaying(_currentSong!.id);
    _preloadUpcomingSongs();
    unawaited(_saveCurrentState());
    notifyListeners();
  }

  void _onQueueCompleted() {
    debugPrint('[audio_player] End of playlist reached');
    _scrobbleCurrentSong();
    _playbackState = PlaybackState.stopped;
    notifyListeners();
  }

  void _onPlayerError(PlayerException error) {
    // setAudioSources() throws its errors, see _loadQueue()
    if (_settingSources || _disposed) return;
    if (_pendingPlayerOps > 0) {
      _deferredError = error;
      return;
    }

    final failedIndex = _entryAt(error.index)?.index ?? _currentIndex;
    debugPrint('[audio_player] Playback error at index $failedIndex: $error');
    final next = _nextCachedIndex(failedIndex);
    if (next != null) {
      debugPrint('[offline] Continuing at cached index $next');
      unawaited(_jumpTo(next).catchError((Object e) {
        _onLoadFailed('Failed to play song: $e');
      }));
      return;
    }

    // Nothing later is playable; play() tries this track again
    _needsSourceReload = true;
    _pendingResumePosition = Duration.zero;
    if (failedIndex != _currentIndex) {
      _setCurrentTrack(failedIndex, playing: false);
    }
    _onLoadFailed('Failed to play song: ${error.message ?? error}');
  }

  /// The first track after [index] that's in the disk cache.
  int? _nextCachedIndex(int index) {
    for (var i = index + 1; i < _playlist.length; i++) {
      if (_audioCache.isCached(_playlist[i].id)) return i;
    }
    return null;
  }

  Future<void> play() async {
    debugPrint(
        '[audio_player] Play requested - currentSong: ${_currentSong?.title}, state: $_playbackState');
    if (_playlist.isEmpty) return;

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

    if (_currentSongStartTime == null) {
      // First play of a song restored from a previous session
      _currentSongStartTime = DateTime.now();
      _onTrackStarted();
    }
    _startPlayback();
  }

  Future<void> pause() async {
    await _audioPlayer.pause();
  }

  Future<void> stop() async {
    // Before stopping the player, so the idle state it reports is final
    _stopped = true;
    await _audioPlayer.stop();
    _currentPosition = Duration.zero;
    _totalDuration = Duration.zero;
    _playbackState = PlaybackState.stopped;
    notifyListeners();
  }

  bool _canSkip() {
    final now = DateTime.now();
    if (_lastSkipTime != null &&
        now.difference(_lastSkipTime!).inMilliseconds <= _skipDebounceMs) {
      return false;
    }
    _lastSkipTime = now;
    return true;
  }

  Future<void> next() => _skip(_currentIndex + 1, 'next');

  Future<void> previous() => _skip(_currentIndex - 1, 'previous');

  Future<void> _skip(int target, String source) async {
    if (target < 0 || target >= _playlist.length) return;
    if (!_canSkip() || _skipOperationInProgress) {
      debugPrint('[$source] Skip ignored');
      return;
    }

    _skipOperationInProgress = true;
    notifyListeners();
    try {
      _scrobbleCurrentSongIfEligible();
      await _jumpTo(target);
    } catch (e) {
      debugPrint('[$source] Error during skip: $e');
      _onLoadFailed('Failed to play song: $e');
    } finally {
      _skipOperationInProgress = false;
      notifyListeners();
    }
  }

  Future<void> seekTo(Duration position) async {
    await _audioPlayer.seek(position);
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

  String _formatDuration(Duration duration) {
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

  /// Makes sure the song at [index] has ReplayGain data, reading it from the
  /// file when the server didn't provide it, and applies the volume if the
  /// song is (still) the current one.
  Future<void> _loadReplayGain(int index) async {
    final playlist = _playlist;
    final song = playlist[index];
    _rgLog('[ReplayGain] Processing song: "${song.title}" by "${song.artist}" '
        '(id=${song.id}, album="${song.album}", format=${song.suffix}/${song.contentType})');

    if (song.replayGainTrackGain == null && song.replayGainAlbumGain == null) {
      _rgLog(
          '[ReplayGain] No ReplayGain in API response, reading from file...');
      final streamUrl = _api.getStreamUrl(song.id);
      _rgLog(
          '[ReplayGain] Stream URL: ${ReplayGainDebugLogger.redact(streamUrl)}');
      try {
        final cachedFile = _audioCache.getCachedFile(song.id);
        final data = cachedFile != null
            ? await ReplayGainReader.readFromFile(cachedFile)
            : await ReplayGainReader.readFromUrl(streamUrl);
        _rgLog('[ReplayGain] File reading complete: '
            'TrackGain=${data.trackGain?.toStringAsFixed(2) ?? "null"}, '
            'AlbumGain=${data.albumGain?.toStringAsFixed(2) ?? "null"}, '
            'TrackPeak=${data.trackPeak?.toStringAsFixed(4) ?? "null"}, '
            'AlbumPeak=${data.albumPeak?.toStringAsFixed(4) ?? "null"}');
        _storeReplayGain(playlist, index, data);
      } catch (e, stackTrace) {
        _rgLog('[ReplayGain] ERROR reading ReplayGain metadata: $e');
        _rgLog('[ReplayGain] Stack trace: $stackTrace');
      }
    }

    if (identical(playlist, _playlist) && index == _currentIndex) {
      _applyReplayGainVolume();
    }
  }

  /// Stores ReplayGain data read from a file in the playlist entry at
  /// [index], if [playlist] is still the current one.
  void _storeReplayGain(List<Song> playlist, int index, ReplayGainData data) {
    if (!data.hasAnyData ||
        !identical(playlist, _playlist) ||
        index >= playlist.length) {
      return;
    }
    final song = playlist[index];
    final updated = Song(
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
      replayGainTrackGain: data.trackGain,
      replayGainAlbumGain: data.albumGain,
      replayGainTrackPeak: data.trackPeak,
      replayGainAlbumPeak: data.albumPeak,
    );
    playlist[index] = updated;
    // Not notified: only the volume depends on it
    if (index == _currentIndex) _currentSong = updated;
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

  /// Downloads upcoming songs in the playlist to the disk cache so playback
  /// can continue if the network drops. Downloads run one at a time, nearest
  /// track first, so the next song is ready as early as possible. Each
  /// finished download replaces the stream in the player's sequence.
  Future<void> _preloadUpcomingSongs() async {
    final playlist = _playlist;
    final generation = _generation;
    final start = _currentIndex + 1;
    final end = (start + _maxPreloadTracks).clamp(0, playlist.length);
    if (start >= end) return;

    for (var index = start; index < end; index++) {
      // Stop if the playlist was replaced while downloading
      if (_disposed || !identical(playlist, _playlist)) break;
      final file = await _preloadSingleTrack(playlist, index);
      if (file != null) {
        await _useCachedFile(generation, index, file);
      }
    }
  }

  /// Downloads the track at [index] and reads its ReplayGain metadata from
  /// the downloaded file if the server didn't provide it.
  Future<File?> _preloadSingleTrack(List<Song> playlist, int index) async {
    final song = playlist[index];
    try {
      final file = await _audioCache.prefetch(
        song.id,
        _api.getStreamUrl(song.id),
        suffix: song.suffix,
      );
      if (file == null) return null;

      if (song.replayGainTrackGain == null &&
          song.replayGainAlbumGain == null) {
        final data = await ReplayGainReader.readFromFile(file);
        _rgLog(
            '[ReplayGain] Preload read "${song.title}": Track=${data.trackGain}, Album=${data.albumGain}');
        _storeReplayGain(playlist, index, data);
      }
      return file;
    } catch (e) {
      debugPrint('Error preloading track $index (${song.title}): $e');
      // Don't rethrow - continue with other preloads
      return null;
    }
  }

  /// Replaces the stream of the upcoming track at [index] in the player's
  /// sequence with its downloaded [file]: it then plays without the network
  /// and isn't downloaded a second time. The file is inserted before the
  /// stream is removed, so positions up to the current track never shift.
  Future<void> _useCachedFile(int generation, int index, File file) =>
      _playerOp(() async {
        if (_disposed ||
            generation != _generation ||
            index <= _currentIndex ||
            _fileBacked.contains(index)) {
          return;
        }
        if (index == _currentIndex + 1 &&
            _totalDuration > Duration.zero &&
            _totalDuration - _currentPosition < _swapCutoff) {
          return;
        }
        try {
          await _audioPlayer.insertAudioSource(
              index, _sourceFor(generation, index, file: file));
          await _audioPlayer.removeAudioSourceAt(index + 1);
          _fileBacked.add(index);
          debugPrint('[audio_cache] Index $index now plays from the cache');
        } catch (e) {
          debugPrint('[audio_cache] Could not swap in index $index: $e');
        }
      });

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

    debugPrint('Sleep timer started for ${_formatDuration(duration)}');

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
          'Sleep timer extended by ${_formatDuration(extension)}, new remaining: ${_formatDuration(newDuration)}');

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
    _playerStateSubscription?.cancel();
    _currentIndexSubscription?.cancel();
    _errorSubscription?.cancel();
    _sleepTimer?.cancel();
    if (_ownsAudioCache) _audioCache.dispose();
    _persistence?.dispose();
    _scrobbleQueue.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }
}
