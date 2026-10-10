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
  final StreamController<int?> _indexController =
      StreamController<int?>.broadcast();

  PlayerState _currentPlayerState = PlayerState(false, ProcessingState.idle);

  /// Every source loaded into the player, in order: the URL for streams,
  /// `file:<path>` for cached files.
  final List<String> loadedSources = [];

  /// URLs that fail to load, as when the network is down.
  final Set<String> failingUrls = {};

  /// The player's current sequence, in the same notation as [loadedSources].
  final List<String> sequenceSources = [];
  // The source objects behind [sequenceSources], so [sequence] returns the
  // same instances on every call, as just_audio does
  final List<IndexedAudioSource> _sequence = [];
  int? _currentIndex;

  /// Every volume set on the player, in order.
  final List<double> volumes = [];

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
  Stream<int?> get currentIndexStream => _indexController.stream;

  @override
  int? get currentIndex => _currentIndex;

  @override
  List<IndexedAudioSource> get sequence => List.unmodifiable(_sequence);

  /// Replaces the sequence with [source], as setUrl/setFilePath do.
  void _loadSingle(String source, Duration? initialPosition) {
    loadedSources.add(source);
    sequenceSources
      ..clear()
      ..add(source);
    _sequence
      ..clear()
      ..add(source.startsWith('file:')
          ? AudioSource.file(source.substring(5))
          : AudioSource.uri(Uri.parse(source)));
    _currentIndex = 0;
    _indexController.add(0);
    _duration = const Duration(minutes: 3);
    _durationController.add(_duration);
    _position = initialPosition ?? Duration.zero;
    _positionController.add(_position);
  }

  @override
  Future<void> addAudioSource(AudioSource audioSource) async {
    final source = audioSource as UriAudioSource;
    sequenceSources.add(source.uri.scheme == 'file'
        ? 'file:${source.uri.toFilePath()}'
        : '${source.uri}');
    _sequence.add(source);
    // just_audio broadcasts the sequence state on every change, which
    // re-emits the current index
    _indexController.add(_currentIndex);
  }

  @override
  Future<void> removeAudioSourceAt(int index) async {
    sequenceSources.removeAt(index);
    _sequence.removeAt(index);
    // just_audio re-emits the index it last got from the platform before the
    // platform reports the shifted one
    _indexController.add(_currentIndex);
    if (_currentIndex != null && index < _currentIndex!) {
      _currentIndex = _currentIndex! - 1;
      _indexController.add(_currentIndex);
    }
  }

  @override
  Future<Duration?> setUrl(String url,
      {Map<String, String>? headers,
      Duration? initialPosition,
      bool preload = true,
      dynamic tag}) async {
    if (failingUrls.contains(url)) {
      throw Exception('Network unreachable: $url');
    }
    _loadSingle(url, initialPosition);
    return _duration;
  }

  @override
  Future<Duration?> setFilePath(String filePath,
      {Duration? initialPosition, bool preload = true, dynamic tag}) async {
    _loadSingle('file:$filePath', initialPosition);
    return _duration;
  }

  @override
  Future<void> play() async {
    _currentPlayerState = PlayerState(true, ProcessingState.ready);
    _stateController.add(_currentPlayerState);

    // Playback continues from the current position
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
    volumes.add(volume);
  }

  @override
  Future<void> dispose() async {
    await _positionController.close();
    await _durationController.close();
    await _stateController.close();
    await _indexController.close();
  }

  // Helper methods for testing
  void simulateCompletion() {
    _currentPlayerState = PlayerState(false, ProcessingState.completed);
    _stateController.add(_currentPlayerState);
  }

  /// The player reaching the end of the current item and moving on to the
  /// next one in its sequence, as it does for gapless playback.
  void simulateTrackTransition(
      {Duration duration = const Duration(minutes: 4)}) {
    assert(_currentIndex! + 1 < sequenceSources.length,
        'no next item in the sequence');
    _currentIndex = _currentIndex! + 1;
    _indexController.add(_currentIndex);
    _duration = duration;
    _durationController.add(_duration);
    _position = Duration.zero;
    _positionController.add(_position);
  }

  /// A playback event from the platform reporting [index]. just_audio
  /// re-emits the current index with every playback event, and an event can
  /// arrive after the sequence already changed.
  void simulateIndexEvent(int? index) {
    _indexController.add(index);
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
