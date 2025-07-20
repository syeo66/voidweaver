import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'audio_player_service.dart' as aps;
import 'subsonic_api.dart';

class VoidweaverAudioHandler extends BaseAudioHandler {
  final aps.AudioPlayerService _audioPlayerService;
  final SubsonicApi _api;
  late StreamSubscription _positionSubscription;

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

    // Set initial state
    _updatePlaybackState();
  }

  void _updatePlaybackState() {
    final song = _audioPlayerService.currentSong;
    final state = _audioPlayerService.playbackState;

    // Update media item
    if (song != null) {
      mediaItem.add(MediaItem(
        id: song.id,
        album: song.album,
        title: song.title,
        artist: song.artist,
        duration: _audioPlayerService.totalDuration,
        artUri: song.coverArt != null
            ? Uri.parse(_api.getCoverArtUrl(song.coverArt!))
            : null,
      ));
    }

    // Update playback state
    final playing = state == aps.PlaybackState.playing;
    final buffering = state == aps.PlaybackState.loading;

    playbackState.add(playbackState.value.copyWith(
      controls: [
        if (_audioPlayerService.hasPrevious) MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        if (_audioPlayerService.hasNext) MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: buffering
          ? AudioProcessingState.loading
          : playing
              ? AudioProcessingState.ready
              : AudioProcessingState.idle,
      playing: playing,
      updatePosition: _audioPlayerService.currentPosition,
      bufferedPosition: _audioPlayerService.currentPosition,
      speed: playing ? 1.0 : 0.0,
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
    await _audioPlayerService.play();
  }

  @override
  Future<void> pause() async {
    await _audioPlayerService.pause();
  }

  @override
  Future<void> stop() async {
    await _audioPlayerService.stop();
  }

  @override
  Future<void> skipToNext() async {
    debugPrint('[native_controls] Skip next requested from native controls');
    await _audioPlayerService.next();
  }

  @override
  Future<void> skipToPrevious() async {
    debugPrint('[native_controls] Skip previous requested from native controls');
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

  void dispose() {
    _audioPlayerService.removeListener(_updatePlaybackState);
    _positionSubscription.cancel();
  }
}
