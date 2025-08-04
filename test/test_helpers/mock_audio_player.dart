import 'dart:async';
import 'package:just_audio/just_audio.dart';
import 'package:mockito/mockito.dart';

class MockAudioPlayer extends Mock implements AudioPlayer {
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durationController =
      StreamController<Duration?>.broadcast();
  final StreamController<PlayerState> _stateController =
      StreamController<PlayerState>.broadcast();

  PlayerState _currentPlayerState = PlayerState(false, ProcessingState.idle);
  Duration? _duration;
  Duration _position = Duration.zero;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration?> get durationStream => _durationController.stream;

  @override
  Stream<PlayerState> get playerStateStream => _stateController.stream;

  @override
  PlayerState get playerState => _currentPlayerState;

  @override
  Duration? get duration => _duration;

  @override
  Duration get position => _position;

  @override
  Future<Duration?> setUrl(String url,
      {Map<String, String>? headers,
      Duration? initialPosition,
      bool preload = true,
      dynamic tag}) async {
    // Simulate setting URL and getting duration
    _duration = const Duration(minutes: 3);
    _durationController.add(_duration);
    return _duration;
  }

  @override
  Future<void> play() async {
    _currentPlayerState = PlayerState(true, ProcessingState.ready);
    _stateController.add(_currentPlayerState);

    // Simulate position updates
    _position = Duration.zero;
    _positionController.add(_position);
  }

  @override
  Future<void> pause() async {
    _currentPlayerState = PlayerState(false, ProcessingState.ready);
    _stateController.add(_currentPlayerState);
  }

  @override
  Future<void> stop() async {
    _currentPlayerState = PlayerState(false, ProcessingState.idle);
    _stateController.add(_currentPlayerState);
    _position = Duration.zero;
    _positionController.add(_position);
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    _position = position ?? Duration.zero;
    _positionController.add(_position);
  }

  @override
  Future<void> setVolume(double volume) async {
    // Mock implementation - do nothing
  }

  @override
  Future<void> dispose() async {
    await _positionController.close();
    await _durationController.close();
    await _stateController.close();
  }

  // Helper methods for testing
  void simulateCompletion() {
    _currentPlayerState = PlayerState(false, ProcessingState.completed);
    _stateController.add(_currentPlayerState);
  }

  void simulatePositionChange(Duration position) {
    _position = position;
    _positionController.add(_position);
  }

  void simulateDurationChange(Duration? duration) {
    _duration = duration;
    _durationController.add(_duration);
  }

  // Additional just_audio specific methods that might be needed
  @override
  Future<Duration?> setAudioSource(AudioSource source,
      {bool preload = true,
      int? initialIndex,
      Duration? initialPosition}) async {
    // Mock implementation
    return _duration;
  }

  @override
  Future<Duration?> load() async {
    // Mock implementation
    return _duration;
  }
}
