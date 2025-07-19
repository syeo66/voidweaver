import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:mockito/mockito.dart';

class MockAudioPlayer extends Mock implements AudioPlayer {
  final StreamController<Duration> _positionController =
      StreamController<Duration>();
  final StreamController<Duration> _durationController =
      StreamController<Duration>();
  final StreamController<void> _completeController = StreamController<void>();
  final StreamController<PlayerState> _stateController =
      StreamController<PlayerState>();

  PlayerState _state = PlayerState.stopped;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  Stream<Duration> get onPositionChanged => _positionController.stream;

  @override
  Stream<Duration> get onDurationChanged => _durationController.stream;

  @override
  Stream<void> get onPlayerComplete => _completeController.stream;

  @override
  Stream<PlayerState> get onPlayerStateChanged => _stateController.stream;

  @override
  PlayerState get state => _state;

  @override
  Future<void> play(Source source,
      {double? volume,
      double? balance,
      AudioContext? ctx,
      Duration? position,
      PlayerMode? mode}) async {
    _state = PlayerState.playing;
    _stateController.add(_state);

    // Simulate duration being set
    _duration = const Duration(minutes: 3);
    _durationController.add(_duration);

    // Simulate position updates
    _position = position ?? Duration.zero;
    _positionController.add(_position);
  }

  @override
  Future<void> pause() async {
    _state = PlayerState.paused;
    _stateController.add(_state);
  }

  @override
  Future<void> resume() async {
    _state = PlayerState.playing;
    _stateController.add(_state);
  }

  @override
  Future<void> stop() async {
    _state = PlayerState.stopped;
    _stateController.add(_state);
    _position = Duration.zero;
    _positionController.add(_position);
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
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
    await _completeController.close();
    await _stateController.close();
  }

  // Helper methods for testing
  void simulateCompletion() {
    _state = PlayerState.completed;
    _stateController.add(_state);
    _completeController.add(null);
  }

  void simulatePositionChange(Duration position) {
    _position = position;
    _positionController.add(_position);
  }

  void simulateDurationChange(Duration duration) {
    _duration = duration;
    _durationController.add(_duration);
  }
}
