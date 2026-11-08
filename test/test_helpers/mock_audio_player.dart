import 'dart:async';

import 'package:mockito/mockito.dart';
import 'package:voidweaver_player/voidweaver_player.dart';

/// A fake [VoidweaverPlayer] holding a sequence of sources, like the real
/// one: it moves to the next item by itself at the end of a track (see
/// [simulateTrackTransition]) and reports load errors on [errorStream].
class MockAudioPlayer extends Mock implements VoidweaverPlayer {
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
  final StreamController<SystemCommand> _commandController =
      StreamController<SystemCommand>.broadcast();

  PlayerState _currentPlayerState = PlayerState(false, ProcessingState.idle);

  /// Every item the player was explicitly told to play, by setting the
  /// sequence or seeking to an index, in order, by URL. Moving on at the end
  /// of a track isn't recorded.
  final List<String> loadedSources = [];

  /// URLs that fail to load, as when the network is down. Like the real
  /// player, items whose cache key is cached ([isCached]) still play.
  final Set<String> failingUrls = {};

  /// Whether the content for a cache key is cached, see [AudioSource.cacheKey]
  final bool Function(String? cacheKey) isCached;

  MockAudioPlayer({bool Function(String? cacheKey)? isCached})
    : isCached = isCached ?? ((_) => false);

  /// The player's current sequence, in the same notation as [loadedSources].
  List<String> get sequenceSources => [for (final s in _sequence) _describe(s)];

  final List<AudioSource> _sequence = [];
  int? _currentIndex;

  final Map<String, double> _gains = {};

  /// While set, a seek to another item waits for it to complete, like an
  /// item that takes a while to load: the player moves to the item at once,
  /// buffering, and the seek completes once it's ready.
  Completer<void>? seekGate;

  /// While set, setting the sequence waits for it to complete, like a first
  /// track that takes a while to load.
  Completer<void>? loadGate;

  // The load and the seek waiting at their gate. Like the real player
  // (PlaylistPlayer's interruptLoad() and completeSeek()), a new sequence or
  // stop() ends a waiting load with PlayerInterruptedException, a load error
  // ends it with the error, and any other seek, load, stop() or error
  // completes a waiting seek.
  Completer<void>? _pendingLoad;
  Completer<void>? _pendingSeek;

  void _interruptLoad([Object? error]) {
    final load = _pendingLoad;
    _pendingLoad = null;
    load?.completeError(
      error ?? PlayerInterruptedException('Loading interrupted'),
    );
  }

  void _completeSeek() {
    final seek = _pendingSeek;
    _pendingSeek = null;
    seek?.complete();
  }

  /// The gain of the item for [source] (in the notation of
  /// [sequenceSources]) in the current sequence.
  double? gainOfSource(String source) {
    for (final s in _sequence) {
      if (_describe(s) == source) return gainOf(s);
    }
    return null;
  }

  Duration? _duration;
  Duration _position = Duration.zero;

  static String _describe(AudioSource source) => '${source.uri}';

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration?> get durationStream => _durationController.stream;

  @override
  Stream<PlayerState> get playerStateStream => _stateController.stream;

  @override
  Stream<ProcessingState> get processingStateStream =>
      playerStateStream.map((state) => state.processingState).distinct();

  @override
  Stream<PlayerException> get errorStream => _errorController.stream;

  @override
  Stream<SystemCommand> get commandStream => _commandController.stream;

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
  List<AudioSource> get sequence => List.unmodifiable(_sequence);

  /// Why the player is idle: after [stop], or after an item failed to load
  /// (see [failures]). Null while it isn't idle, or before anything loaded.
  String? idleCause;

  /// How many times an item failed to load, by a load error or a failing
  /// URL: each one leaves the player idle
  int failures = 0;

  /// Called with each seek within the current item, before it's carried out
  void Function(Duration position)? onSeekWithinItem;

  void _setState(bool playing, ProcessingState processingState) {
    if (processingState != ProcessingState.idle) idleCause = null;
    _currentPlayerState = PlayerState(playing, processingState);
    _stateController.add(_currentPlayerState);
  }

  bool _fails(int index) =>
      failingUrls.contains(_describe(_sequence[index])) &&
      !isCached(_sequence[index].cacheKey);

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
    final error = PlayerException(0, 'Source error', _currentIndex);
    failures++;
    _setState(playing, ProcessingState.idle);
    idleCause = 'error';
    _errorController.add(error);
    _interruptLoad(error);
    _completeSeek();
  }

  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> audioSources, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) async {
    _interruptLoad();
    _completeSeek();
    _sequence
      ..clear()
      ..addAll(audioSources);
    _gains.clear();
    final index = initialIndex;
    loadedSources.add(_describe(_sequence[index]));
    _moveTo(index, initialPosition);
    final gate = loadGate;
    if (gate != null) {
      final load = _pendingLoad = Completer<void>();
      _setState(playing, ProcessingState.buffering);
      // Throws if a new sequence, stop() or a load error ends the load first
      await Future.any([gate.future, load.future]);
      _pendingLoad = null;
    }
    if (_fails(index)) {
      failures++;
      _setState(playing, ProcessingState.idle);
      idleCause = 'error';
      throw PlayerException(0, 'Network unreachable', index);
    }
    _setState(playing, ProcessingState.ready);
    return _duration;
  }

  /// What [takeResumeRequest] answers (once)
  bool resumeRequested = false;

  @override
  Future<bool> takeResumeRequest() async {
    final requested = resumeRequested;
    resumeRequested = false;
    return requested;
  }

  /// Like ExoPlayer's playWhenReady: an idle player stays idle (it has to
  /// load first), a buffering one plays once it's ready, a completed one
  /// stays completed.
  @override
  Future<void> play() async {
    _setState(true, processingState);

    // Playback continues from the current position
    _positionController.add(_position);
  }

  @override
  Future<void> pause() async {
    _setState(false, processingState);
  }

  @override
  Future<void> stop() async {
    _interruptLoad();
    _completeSeek();
    _setState(false, ProcessingState.idle);
    idleCause = 'stop';
    _position = Duration.zero;
    _positionController.add(_position);
  }

  /// Targets of the seeks within the current item, in order
  final List<Duration> seeks = [];

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    _completeSeek();
    if (index == null || index == _currentIndex) {
      onSeekWithinItem?.call(position ?? Duration.zero);
      seeks.add(position ?? Duration.zero);
      _position = position ?? Duration.zero;
      _positionController.add(_position);
      // A completed player seeks back into the item
      if (processingState == ProcessingState.completed) {
        _setState(playing, ProcessingState.ready);
      }
      return;
    }
    // Like Media3 (ExoPlayerImpl.seekTo), an index past the end of the
    // sequence is ignored
    if (index >= _sequence.length) return;
    // An idle player (stopped, or after an error) moves to the item but
    // doesn't load it, and the seek completes at once (PlaylistPlayer)
    if (processingState == ProcessingState.idle) {
      _moveTo(index, position ?? Duration.zero);
      return;
    }
    loadedSources.add(_describe(_sequence[index]));
    _moveTo(index, position ?? Duration.zero);
    final gate = seekGate;
    if (gate != null) {
      final seek = _pendingSeek = Completer<void>();
      _setState(playing, ProcessingState.buffering);
      await Future.any([gate.future, seek.future]);
      // Completed by a later seek, load, stop() or error
      if (seek.isCompleted) return;
      _pendingSeek = null;
    }
    if (_fails(index)) {
      // Like the real player, the seek completes once the item has failed
      // and the error was reported
      await Future.microtask(_failCurrent);
      return;
    }
    // A seek takes a completed player back into the sequence
    if (gate != null || processingState == ProcessingState.completed) {
      _setState(playing, ProcessingState.ready);
    }
  }

  @override
  double gainOf(AudioSource source) => _gains[source.id] ?? source.gain;

  @override
  Future<void> setGain(AudioSource source, double gain) async {
    _gains[source.id] = gain;
  }

  /// Every volume set, in order
  final List<double> volumes = [];

  @override
  double volume = 1.0;

  @override
  Future<void> setVolume(double volume) async {
    volume = volume.clamp(0.0, 1.0);
    if (volume == this.volume) return;
    this.volume = volume;
    volumes.add(volume);
  }

  /// The intervals set with [setPositionUpdateInterval], in order
  final List<Duration> positionIntervals = [];

  @override
  Future<void> setPositionUpdateInterval(Duration interval) async {
    positionIntervals.add(interval);
  }

  @override
  Future<void> dispose() async {
    await _positionController.close();
    await _durationController.close();
    await _stateController.close();
    await _indexController.close();
    await _errorController.close();
    await _commandController.close();
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
  void simulateTrackTransition({
    Duration duration = const Duration(minutes: 4),
  }) {
    assert(
      _currentIndex! + 1 < _sequence.length,
      'no next item in the sequence',
    );
    _moveTo(_currentIndex! + 1, Duration.zero);
    _duration = duration;
    _durationController.add(_duration);
    if (_fails(_currentIndex!)) _failCurrent();
  }

  /// A playback event from the platform reporting [index]. An event can
  /// arrive after the sequence already changed.
  void simulateIndexEvent(int? index) {
    _indexController.add(index);
  }

  /// A command from the notification, lock screen, Bluetooth or media
  /// buttons.
  void simulateSystemCommand(SystemCommandType type, [Duration? position]) =>
      _commandController.add(SystemCommand(type, position));

  /// A load error for the current item, e.g. the network dropping while it
  /// streams.
  void simulateLoadError() => _failCurrent();

  /// The current item running out of buffered data while it plays.
  void simulateBuffering() => _setState(playing, ProcessingState.buffering);

  /// Another app taking the audio focus for good (e.g. starting its own
  /// playback): ExoPlayer pauses by itself, without a call from the service.
  void simulateFocusLoss() => _setState(false, processingState);

  /// Enough data buffered again after [simulateBuffering], or for a load or
  /// seek waiting at its gate: the item plays on, or stays paused. Like the
  /// real player, a load or seek waiting to be ready completes.
  void simulateBufferingEnd() {
    _setState(playing, ProcessingState.ready);
    final load = _pendingLoad;
    _pendingLoad = null;
    load?.complete();
    _completeSeek();
  }

  /// A position update without time passing, like after a seek. See
  /// [simulatePlayingTo] for playback.
  void simulatePositionChange(Duration position) {
    _position = position;
    _positionController.add(_position);
  }

  /// The time for the service under test; pass [clock] as its `clock`.
  /// [simulatePlayingTo] advances it.
  DateTime now = DateTime(2026);
  DateTime clock() => now;

  /// Playback continuing to [position]: [clock] advances by as much as the
  /// position does, so the service counts it as listened to.
  void simulatePlayingTo(Duration position) {
    if (position > _position) now = now.add(position - _position);
    simulatePositionChange(position);
  }

  void simulateDurationChange(Duration? duration) {
    _duration = duration;
    _durationController.add(_duration);
  }
}
