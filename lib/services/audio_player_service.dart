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
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _playerCompleteSubscription;

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
    _playlist = await _api.getRandomSongs(count);
    _currentIndex = 0;
    await _playSongAtIndex(0);
  }

  Future<void> playSong(Song song) async {
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
      final streamUrl = _api.getStreamUrl(_currentSong!.id);
      debugPrint('Playing song: ${_currentSong!.title} from URL: $streamUrl');
      await _audioPlayer.play(UrlSource(streamUrl));
      
      // Read ReplayGain metadata from the audio file and apply volume adjustment
      _readReplayGainAndApplyVolume(streamUrl);
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
      await _playSongAtIndex(_currentIndex + 1);
    }
  }

  Future<void> previous() async {
    if (hasPrevious) {
      await _playSongAtIndex(_currentIndex - 1);
    }
  }

  Future<void> seekTo(Duration position) async {
    await _audioPlayer.seek(position);
  }

  void _onSongComplete() {
    if (hasNext) {
      _playSongAtIndex(_currentIndex + 1);
    } else {
      _playbackState = PlaybackState.stopped;
      notifyListeners();
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

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playerCompleteSubscription?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }
}