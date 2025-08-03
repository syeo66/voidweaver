import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'audio_player_service.dart' as aps;
import 'subsonic_api.dart';

class VoidweaverAudioHandler extends BaseAudioHandler with SeekHandler {
  final aps.AudioPlayerService _audioPlayerService;
  final SubsonicApi _api;
  late StreamSubscription _positionSubscription;
  late StreamSubscription _directPlayerStateSubscription;
  static const MethodChannel _audioFocusChannel =
      MethodChannel('voidweaver/audio_focus');
  
  // State masking for skip operations
  bool _lastKnownPlayingState = false;

  VoidweaverAudioHandler(this._audioPlayerService, this._api) {
    _init();
  }

  void _init() {
    // Listen to MediaItem changes from AudioPlayerService (track info, loading states)
    _audioPlayerService.addListener(_updateMediaItem);

    // Listen directly to just_audio PlayerState for real-time system state updates
    _directPlayerStateSubscription = _audioPlayerService.audioPlayer.playerStateStream.listen((playerState) {
      _updateSystemPlaybackState(playerState);
    });

    // Listen directly to the audio player's position stream for real-time updates
    _positionSubscription =
        _audioPlayerService.onPositionChanged.listen((position) {
      _updatePosition();
    });

    // Set initial state based on current AudioPlayerService state
    _updateMediaItem();
    
    // Initialize with inactive media session that will be activated on play
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
  }

  void _updateMediaItem() {
    final song = _audioPlayerService.currentSong;

    // Update media item and activate media session
    if (song != null) {
      final newMediaItem = MediaItem(
        id: song.id,
        album: song.album,
        title: song.title,
        artist: song.artist,
        duration: _audioPlayerService.totalDuration,
        artUri: song.coverArt != null
            ? Uri.parse(_api.getCoverArtUrl(song.coverArt!))
            : null,
        extras: {
          'isActive': true,
        },
      );

      // Only update media item if it's actually different
      if (mediaItem.value?.id != newMediaItem.id ||
          mediaItem.value?.title != newMediaItem.title) {
        mediaItem.add(newMediaItem);
        debugPrint(
            '[native_controls] Media item updated: ${song.title} by ${song.artist}');
      }
    } else {
      // Clear media item when no song is playing
      mediaItem.add(null);
    }

    // Update available controls based on playlist state
    _updateControls();
  }

  void _updateSystemPlaybackState(PlayerState playerState) {
    debugPrint('[native_controls] Direct PlayerState update: $playerState');
    
    final isSkipping = _audioPlayerService.isSkipOperationInProgress;
    final actualPlaying = playerState.playing;
    
    // Skip state masking: during skip operations, ignore transient paused states
    bool effectivePlaying;
    if (isSkipping && !actualPlaying) {
      // During skip, ignore just_audio's temporary paused state
      effectivePlaying = _lastKnownPlayingState;
      debugPrint('[native_controls] Skip state masking: ignoring paused state during skip, using last known: $_lastKnownPlayingState');
    } else {
      // Not skipping or skip completed with playing=true, use actual state
      effectivePlaying = actualPlaying;
      // Update last known state when not masking
      if (!isSkipping) {
        _lastKnownPlayingState = actualPlaying;
      }
    }
    
    AudioProcessingState processingState;
    switch (playerState.processingState) {
      case ProcessingState.idle:
        processingState = AudioProcessingState.idle;
        break;
      case ProcessingState.loading:
      case ProcessingState.buffering:
        // During skip operations, show as ready instead of loading to avoid confusion
        processingState = isSkipping ? AudioProcessingState.ready : AudioProcessingState.loading;
        break;
      case ProcessingState.ready:
        processingState = AudioProcessingState.ready;
        break;
      case ProcessingState.completed:
        processingState = AudioProcessingState.completed;
        break;
    }

    debugPrint('[native_controls] State mapping - actual: $actualPlaying, effective: $effectivePlaying, skipping: $isSkipping');

    // Update playback state with masked information
    playbackState.add(playbackState.value.copyWith(
      processingState: processingState,
      playing: effectivePlaying,
      updatePosition: _audioPlayerService.currentPosition,
      bufferedPosition: _audioPlayerService.currentPosition,
      speed: effectivePlaying ? 1.0 : 0.0,
    ));
  }

  void _updateControls() {
    // Update available controls based on current playlist state
    playbackState.add(playbackState.value.copyWith(
      controls: [
        if (_audioPlayerService.hasPrevious) MediaControl.skipToPrevious,
        MediaControl.rewind,
        if (playbackState.value.playing) MediaControl.pause else MediaControl.play,
        MediaControl.fastForward,
        if (_audioPlayerService.hasNext) MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.play,
        MediaAction.pause,
        MediaAction.stop,
        MediaAction.skipToPrevious,
        MediaAction.skipToNext,
        MediaAction.rewind,
        MediaAction.fastForward,
      },
      androidCompactActionIndices: const [0, 2, 4],
      repeatMode: AudioServiceRepeatMode.none,
      shuffleMode: AudioServiceShuffleMode.none,
    ));
  }

  void _updatePosition() {
    if (_audioPlayerService.currentSong != null) {
      playbackState.add(playbackState.value.copyWith(
        updatePosition: _audioPlayerService.currentPosition,
      ));
    }
  }

  @override
  Future<void> play() async {
    debugPrint('[native_controls] Play requested from native controls');

    // Only request audio focus on manual play, not during state updates
    _requestAudioFocus();

    await _audioPlayerService.play();
  }

  @override
  Future<void> pause() async {
    debugPrint('[native_controls] Pause requested from native controls');
    await _audioPlayerService.pause();
  }

  @override
  Future<void> stop() async {
    await _audioPlayerService.stop();
    await _abandonAudioFocus();
  }

  @override
  Future<void> skipToNext() async {
    debugPrint('[native_controls] Skip next requested from native controls');
    // Don't request audio focus during skip - app should already have it if playing
    await _audioPlayerService.next();
  }

  @override
  Future<void> skipToPrevious() async {
    debugPrint(
        '[native_controls] Skip previous requested from native controls');
    // Don't request audio focus during skip - app should already have it if playing
    await _audioPlayerService.previous();
  }

  @override
  Future<void> seek(Duration position) async {
    await _audioPlayerService.seekTo(position);
  }

  @override
  Future<void> seekForward(bool begin) async {
    if (begin) {
      final newPosition =
          _audioPlayerService.currentPosition + const Duration(seconds: 10);
      await _audioPlayerService.seekTo(newPosition);
    }
  }

  @override
  Future<void> seekBackward(bool begin) async {
    if (begin) {
      final newPosition =
          _audioPlayerService.currentPosition - const Duration(seconds: 10);
      final clampedPosition =
          newPosition < Duration.zero ? Duration.zero : newPosition;
      await _audioPlayerService.seekTo(clampedPosition);
    }
  }

  @override
  Future<void> fastForward() async {
    debugPrint('[native_controls] Fast forward requested from native controls');
    final newPosition =
        _audioPlayerService.currentPosition + const Duration(seconds: 30);
    await _audioPlayerService.seekTo(newPosition);
  }

  @override
  Future<void> rewind() async {
    debugPrint('[native_controls] Rewind requested from native controls');
    final newPosition =
        _audioPlayerService.currentPosition - const Duration(seconds: 30);
    final clampedPosition =
        newPosition < Duration.zero ? Duration.zero : newPosition;
    await _audioPlayerService.seekTo(clampedPosition);
  }

  /// Request audio focus to ensure this app receives media button events
  void _requestAudioFocus() {
    // Make this non-blocking to prevent interference with playback
    _audioFocusChannel.invokeMethod('requestAudioFocus').then((_) {
      debugPrint('[native_controls] Audio focus requested');
    }).catchError((e) {
      debugPrint('[native_controls] Failed to request audio focus: $e');
    });
  }

  /// Abandon audio focus when stopping playback
  Future<void> _abandonAudioFocus() async {
    try {
      await _audioFocusChannel.invokeMethod('abandonAudioFocus');
      debugPrint('[native_controls] Audio focus abandoned');
    } catch (e) {
      debugPrint('[native_controls] Failed to abandon audio focus: $e');
    }
  }

  void dispose() {
    _abandonAudioFocus();
    _audioPlayerService.removeListener(_updateMediaItem);
    _positionSubscription.cancel();
    _directPlayerStateSubscription.cancel();
  }
}
