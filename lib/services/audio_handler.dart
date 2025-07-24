import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'audio_player_service.dart' as aps;
import 'subsonic_api.dart';

class VoidweaverAudioHandler extends BaseAudioHandler with SeekHandler {
  final aps.AudioPlayerService _audioPlayerService;
  final SubsonicApi _api;
  late StreamSubscription _positionSubscription;
  static const MethodChannel _audioFocusChannel =
      MethodChannel('voidweaver/audio_focus');

  VoidweaverAudioHandler(this._audioPlayerService, this._api) {
    _init();
  }

  void _init() {
    // Listen to playback state changes from AudioPlayerService
    _audioPlayerService.addListener(_updatePlaybackState);

    // Listen directly to the audio player's position stream for real-time updates
    _positionSubscription =
        _audioPlayerService.onPositionChanged.listen((position) {
      _updatePosition();
    });

    // Set initial state and activate media session
    _updatePlaybackState();

    // Initialize with inactive media session that will be activated on play
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
  }

  void _updatePlaybackState() {
    final song = _audioPlayerService.currentSong;
    final state = _audioPlayerService.playbackState;

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

    // Update playback state
    final playing = state == aps.PlaybackState.playing;
    final buffering = state == aps.PlaybackState.loading;

    // Note: Removed aggressive audio focus requests that interfered with playback

    playbackState.add(playbackState.value.copyWith(
      controls: [
        if (_audioPlayerService.hasPrevious) MediaControl.skipToPrevious,
        MediaControl.rewind,
        if (playing) MediaControl.pause else MediaControl.play,
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
      processingState: buffering
          ? AudioProcessingState.loading
          : playing
              ? AudioProcessingState.ready
              : AudioProcessingState.idle,
      playing: playing,
      updatePosition: _audioPlayerService.currentPosition,
      bufferedPosition: _audioPlayerService.currentPosition,
      speed: playing ? 1.0 : 0.0,
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
    // Request audio focus only on user-initiated skip
    _requestAudioFocus();
    await _audioPlayerService.next();
  }

  @override
  Future<void> skipToPrevious() async {
    debugPrint(
        '[native_controls] Skip previous requested from native controls');
    // Request audio focus only on user-initiated skip
    _requestAudioFocus();
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
    _audioPlayerService.removeListener(_updatePlaybackState);
    _positionSubscription.cancel();
  }
}
