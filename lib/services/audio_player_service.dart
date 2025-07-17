import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
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

class AudioPlayerService extends ChangeNotifier {
  final AudioPlayer _audioPlayer = AudioPlayer();
  final SubsonicApi _api;
  final SettingsService _settingsService;
  
  PlaybackState _playbackState = PlaybackState.stopped;
  List<Song> _playlist = [];
  int _currentIndex = 0;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  Song? _currentSong;
  DateTime? _currentSongStartTime;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _playerCompleteSubscription;
  
  // Preload state
  Song? _preloadedSong;
  bool _isPreloading = false;
  String? _preloadedStreamUrl;

  AudioPlayerService(this._api, this._settingsService) {
    _initializePlayer();
  }

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

  void _initializePlayer() {
    _positionSubscription = _audioPlayer.onPositionChanged.listen((position) {
      _currentPosition = position;
      notifyListeners();
    });

    _durationSubscription = _audioPlayer.onDurationChanged.listen((duration) {
      _totalDuration = duration;
      notifyListeners();
    });

    _playerCompleteSubscription = _audioPlayer.onPlayerComplete.listen((_) {
      _onSongComplete();
    });

    _audioPlayer.onPlayerStateChanged.listen((state) {
      switch (state) {
        case PlayerState.playing:
          _playbackState = PlaybackState.playing;
          break;
        case PlayerState.paused:
          _playbackState = PlaybackState.paused;
          break;
        case PlayerState.stopped:
          _playbackState = PlaybackState.stopped;
          break;
        case PlayerState.completed:
          _playbackState = PlaybackState.stopped;
          break;
        case PlayerState.disposed:
          _playbackState = PlaybackState.stopped;
          break;
      }
      notifyListeners();
    });
  }

  Future<void> playAlbum(Album album) async {
    try {
      _playbackState = PlaybackState.loading;
      notifyListeners();
      
      // Clear any existing preload since we're changing playlist
      _clearPreload();
      
      if (album.songs.isEmpty) {
        debugPrint('Album ${album.name} has no songs, trying to fetch from API...');
        try {
          final fullAlbum = await _api.getAlbum(album.id);
          _playlist = fullAlbum.songs;
        } catch (e) {
          debugPrint('Failed to fetch album details: $e');
          // If we can't get album details, we can't play it
          _playbackState = PlaybackState.stopped;
          notifyListeners();
          throw Exception('Could not load album songs: ${e.toString()}');
        }
      } else {
        _playlist = album.songs;
      }
      
      if (_playlist.isEmpty) {
        _playbackState = PlaybackState.stopped;
        notifyListeners();
        throw Exception('Album has no songs');
      }
      
      debugPrint('Playing album: ${album.name} with ${_playlist.length} songs');
      _currentIndex = 0;
      await _playSongAtIndex(0);
    } catch (e) {
      debugPrint('Error playing album: $e');
      _playbackState = PlaybackState.stopped;
      notifyListeners();
      throw Exception('Failed to play album: ${e.toString()}');
    }
  }

  Future<void> playRandomSongs([int count = 50]) async {
    try {
      _playbackState = PlaybackState.loading;
      notifyListeners();
      
      // Clear any existing preload since we're changing playlist
      _clearPreload();
      
      _playlist = await _api.getRandomSongs(count);
      
      if (_playlist.isEmpty) {
        _playbackState = PlaybackState.stopped;
        notifyListeners();
        throw Exception('No random songs available');
      }
      
      debugPrint('Playing random songs: ${_playlist.length} songs loaded');
      _currentIndex = 0;
      await _playSongAtIndex(0);
    } catch (e) {
      debugPrint('Error playing random songs: $e');
      _playbackState = PlaybackState.stopped;
      notifyListeners();
      throw Exception('Failed to play random songs: ${e.toString()}');
    }
  }

  Future<void> playSong(Song song) async {
    // Clear any existing preload since we're changing playlist
    _clearPreload();
    
    _playlist = [song];
    _currentIndex = 0;
    await _playSongAtIndex(0);
  }

  Future<void> _playSongAtIndex(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    
    _currentIndex = index;
    _currentSong = _playlist[index];
    _playbackState = PlaybackState.loading;
    
    notifyListeners();

    try {
      String streamUrl;
      
      // Check if this song is already preloaded
      if (_preloadedSong?.id == _currentSong!.id && _preloadedStreamUrl != null) {
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
      
      await _audioPlayer.play(UrlSource(streamUrl));
      
      // Send now playing notification to server
      _api.scrobbleNowPlaying(_currentSong!.id);
      
      // Read ReplayGain metadata from the audio file and apply volume adjustment
      _readReplayGainAndApplyVolume(streamUrl);
      
      // Preload next song if available
      _preloadNextSong();
    } catch (e) {
      debugPrint('Error playing song at index $index: $e');
      _playbackState = PlaybackState.stopped;
      notifyListeners();
      throw Exception('Failed to play song: $e');
    }
  }

  Future<void> play() async {
    if (_currentSong == null && _playlist.isNotEmpty) {
      await _playSongAtIndex(_currentIndex);
    } else {
      await _audioPlayer.resume();
    }
  }

  Future<void> pause() async {
    await _audioPlayer.pause();
  }

  Future<void> stop() async {
    await _audioPlayer.stop();
    _currentPosition = Duration.zero;
    _totalDuration = Duration.zero;
    _playbackState = PlaybackState.stopped;
    notifyListeners();
  }

  Future<void> next() async {
    if (hasNext) {
      // Scrobble current song if it has been played enough
      _scrobbleCurrentSongIfEligible();
      await _playSongAtIndex(_currentIndex + 1);
    }
  }

  Future<void> previous() async {
    if (hasPrevious) {
      // Scrobble current song if it has been played enough
      _scrobbleCurrentSongIfEligible();
      await _playSongAtIndex(_currentIndex - 1);
    }
  }

  Future<void> seekTo(Duration position) async {
    await _audioPlayer.seek(position);
  }

  void _onSongComplete() {
    // Send scrobble submission for the completed song
    _scrobbleCurrentSong();
    
    if (hasNext) {
      _playSongAtIndex(_currentIndex + 1);
    } else {
      _playbackState = PlaybackState.stopped;
      notifyListeners();
    }
  }

  void _scrobbleCurrentSong() {
    if (_currentSong != null && _currentSongStartTime != null) {
      // Send scrobble submission with the timestamp when the song started playing
      _api.scrobbleSubmission(_currentSong!.id, playedAt: _currentSongStartTime!);
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
    if (songDuration.inSeconds > 0 && playedDuration.inSeconds >= songDuration.inSeconds * 0.5) {
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
    if (_currentSong!.replayGainTrackGain != null || _currentSong!.replayGainAlbumGain != null) {
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
    
    debugPrint('Applied ReplayGain volume: ${volumeMultiplier.toStringAsFixed(3)} for song: ${_currentSong!.title}');
    debugPrint('  Mode: $rgMode, TrackGain: ${trackGain?.toStringAsFixed(2) ?? 'null'}, AlbumGain: ${albumGain?.toStringAsFixed(2) ?? 'null'}');
    debugPrint('  Preamp: ${_settingsService.replayGainPreamp.toStringAsFixed(1)}dB, Fallback: ${_settingsService.replayGainFallbackGain.toStringAsFixed(1)}dB');
    debugPrint('  Using ${hasTrackGain || hasAlbumGain ? 'metadata' : 'fallback'} gain');
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
      notifyListeners();
    }
  }
  
  /// Clears the preloaded song (called when playlist changes)
  void _clearPreload() {
    _preloadedSong = null;
    _preloadedStreamUrl = null;
    _isPreloading = false;
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playerCompleteSubscription?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }
}