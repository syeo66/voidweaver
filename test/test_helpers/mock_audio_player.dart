import 'dart:async';
import 'package:just_audio/just_audio.dart';
import 'package:mockito/mockito.dart';

/// A fake just_audio player holding a sequence of sources, like the real one:
/// it moves to the next item by itself at the end of a track (see
/// [simulateTrackTransition]) and reports load errors on [errorStream].
class MockAudioPlayer extends Mock implements AudioPlayer {
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durationController =
      StreamController<Duration?>.broadcast();
  final StreamController<PlayerState> _stateController =
      StreamController<PlayerState>.broadcast();
  final StreamController<int?> _indexController =
      StreamController<int?>.broadcast();
  final StreamController<PlayerException> _errorController =
      StreamController<PlayerException>.broadcast();

  PlayerState _currentPlayerState = PlayerState(false, ProcessingState.idle);

  /// Every item the player was explicitly told to play, by setting the
  /// sequence or seeking to an index, in order: the URL for streams,
  /// `file:<path>` for cached files. Moving on at the end of a track isn't
  /// recorded.
  final List<String> loadedSources = [];

  /// URLs that fail to load, as when the network is down.
  final Set<String> failingUrls = {};

  /// The player's current sequence, in the same notation as [loadedSources].
  List<String> get sequenceSources => [for (final s in _sequence) _describe(s)];

  final List<IndexedAudioSource> _sequence = [];
  int? _currentIndex;

  /// Every volume set on the player, in order.
  final List<double> volumes = [];

  Duration? _duration;
  Duration _position = Duration.zero;

  static String _describe(AudioSource source) {
    final uri = (source as UriAudioSource).uri;
    return uri.scheme == 'file' ? 'file:${uri.toFilePath()}' : '$uri';
  }

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration?> get durationStream => _durationController.stream;

  @override
  Stream<PlayerState> get playerStateStream => _stateController.stream;

  @override
  Stream<PlayerException> get errorStream => _errorController.stream;

  @override
  PlayerState get playerState => _currentPlayerState;

  @override
  bool get playing => _currentPlayerState.playing;

  @override
  ProcessingState get processingState => _currentPlayerState.processingState;

  @override
  Duration? get duration => _duration;

  @override
  Duration get position => _position;

  @override
  Stream<int?> get currentIndexStream => _indexController.stream;

  @override
  int? get currentIndex => _currentIndex;

  @override
  List<IndexedAudioSource> get sequence => List.unmodifiable(_sequence);

  void _setState(bool playing, ProcessingState processingState) {
    _currentPlayerState = PlayerState(playing, processingState);
    _stateController.add(_currentPlayerState);
  }

  bool _fails(int index) => failingUrls.contains(_describe(_sequence[index]));

  /// Makes the item at [index] the current one, starting at [position].
  void _moveTo(int index, Duration position) {
    _currentIndex = index;
    _indexController.add(index);
    _duration = const Duration(minutes: 3);
    _durationController.add(_duration);
    _position = position;
    _positionController.add(_position);
  }

  /// The item at the current index failed to load: the player reports the
  /// error and goes idle.
  void _failCurrent() {
    _setState(playing, ProcessingState.idle);
    _errorController.add(PlayerException(0, 'Source error', _currentIndex));
  }

  @override
  Future<Duration?> setAudioSources(List<AudioSource> audioSources,
      {bool preload = true,
      int? initialIndex,
      Duration? initialPosition,
      ShuffleOrder? shuffleOrder}) async {
    _sequence
      ..clear()
      ..addAll(audioSources.cast<IndexedAudioSource>());
    final index = initialIndex ?? 0;
    loadedSources.add(_describe(_sequence[index]));
    _moveTo(index, initialPosition ?? Duration.zero);
    if (_fails(index)) {
      _setState(playing, ProcessingState.idle);
      throw PlayerException(0, 'Network unreachable', index);
    }
    _setState(playing, ProcessingState.ready);
    return _duration;
  }

  @override
  Future<void> addAudioSource(AudioSource audioSource) async {
    _sequence.add(audioSource as IndexedAudioSource);
    // just_audio broadcasts the sequence state on every change, which
    // re-emits the current index
    _indexController.add(_currentIndex);
  }

  @override
  Future<void> insertAudioSource(int index, AudioSource audioSource) async {
    _sequence.insert(index, audioSource as IndexedAudioSource);
    if (_currentIndex != null && index <= _currentIndex!) {
      _currentIndex = _currentIndex! + 1;
    }
    _indexController.add(_currentIndex);
  }

  @override
  Future<void> removeAudioSourceAt(int index) async {
    _sequence.removeAt(index);
    if (_currentIndex != null && index < _currentIndex!) {
      _currentIndex = _currentIndex! - 1;
    }
    _indexController.add(_currentIndex);
  }

  @override
  Future<void> play() async {
    _setState(true, ProcessingState.ready);

    // Playback continues from the current position
    _positionController.add(_position);
  }

  @override
  Future<void> pause() async {
    _setState(false, processingState);
  }

  @override
  Future<void> stop() async {
    _setState(false, ProcessingState.idle);
    _position = Duration.zero;
    _positionController.add(_position);
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (index == null || index == _currentIndex) {
      _position = position ?? Duration.zero;
      _positionController.add(_position);
      return;
    }
    loadedSources.add(_describe(_sequence[index]));
    _moveTo(index, position ?? Duration.zero);
    // The platform reports a load error after the seek returns
    if (_fails(index)) scheduleMicrotask(_failCurrent);
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
  }

  @override
  Future<void> dispose() async {
    await _positionController.close();
    await _durationController.close();
    await _stateController.close();
    await _indexController.close();
    await _errorController.close();
  }

  // Helper methods for testing

  /// The current track playing to its end: the player moves on to the next
  /// item, or completes after the last one.
  void simulateCompletion() {
    if (_currentIndex != null && _currentIndex! + 1 < _sequence.length) {
      simulateTrackTransition();
    } else {
      _setState(playing, ProcessingState.completed);
    }
  }

  /// The player reaching the end of the current item and moving on to the
  /// next one in its sequence.
  void simulateTrackTransition(
      {Duration duration = const Duration(minutes: 4)}) {
    assert(
        _currentIndex! + 1 < _sequence.length, 'no next item in the sequence');
    _moveTo(_currentIndex! + 1, Duration.zero);
    _duration = duration;
    _durationController.add(_duration);
    if (_fails(_currentIndex!)) _failCurrent();
  }

  /// A playback event from the platform reporting [index]. just_audio
  /// re-emits the current index with every playback event, and an event can
  /// arrive after the sequence already changed.
  void simulateIndexEvent(int? index) {
    _indexController.add(index);
  }

  /// A load error for the current item, e.g. the network dropping while it
  /// streams.
  void simulateLoadError() => _failCurrent();

  void simulatePositionChange(Duration position) {
    _position = position;
    _positionController.add(_position);
  }

  void simulateDurationChange(Duration? duration) {
    _duration = duration;
    _durationController.add(_duration);
  }

  @override
  Future<Duration?> load() async {
    // Mock implementation
    return _duration;
  }
}
