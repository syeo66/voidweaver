/// Gapless playlist player on Media3 ExoPlayer (Android), with a gain stage
/// per item: each item plays at its own gain from its first sample to its
/// last, also across a gapless transition. Its media session drives the
/// notification, lock screen and Bluetooth/media button controls, whose
/// commands arrive on [VoidweaverPlayer.commandStream].
library;

import 'dart:async';

import 'package:flutter/services.dart';

enum ProcessingState { idle, loading, buffering, ready, completed }

class PlayerState {
  /// Whether playback is meant to run. Stays set while buffering and at the
  /// end of the playlist; cleared while audio focus is lost for a moment.
  final bool playing;
  final ProcessingState processingState;

  const PlayerState(this.playing, this.processingState);

  @override
  bool operator ==(Object other) =>
      other is PlayerState &&
      other.playing == playing &&
      other.processingState == processingState;

  @override
  int get hashCode => Object.hash(playing, processingState);

  @override
  String toString() =>
      'PlayerState(playing: $playing, processingState: $processingState)';
}

/// An item failed to load or play.
class PlayerException implements Exception {
  /// ExoPlayer's `PlaybackException.errorCode`
  final int code;
  final String? message;

  /// The playlist index of the item that failed
  final int? index;

  PlayerException(this.code, this.message, [this.index]);

  @override
  String toString() => 'PlayerException($code, $message, index: $index)';
}

/// [VoidweaverPlayer.setAudioSources] was replaced by another call before
/// its start item was ready.
class PlayerInterruptedException implements Exception {
  final String? message;

  PlayerInterruptedException(this.message);

  @override
  String toString() => 'PlayerInterruptedException($message)';
}

enum SystemCommandType { play, pause, stop, next, previous, seek }

/// A command from the notification, lock screen, Bluetooth or media buttons.
/// The player doesn't act on these itself; the app decides what they do.
class SystemCommand {
  final SystemCommandType type;

  /// The target of a [SystemCommandType.seek]
  final Duration? position;

  const SystemCommand(this.type, [this.position]);

  @override
  String toString() => 'SystemCommand($type, $position)';
}

/// A playlist item: a stream URL or a local file, with the metadata the
/// system controls show while it plays.
class AudioSource {
  static int _lastId = 0;

  /// Identifies the item on the native side
  final String id;
  final Uri uri;
  final Object? tag;

  /// Linear gain the item plays at, see [VoidweaverPlayer.setGain]
  final double gain;

  /// Identifies the item's data in the [MediaCache], so a cached item plays
  /// without the network and a streamed one is cached while it plays. Stream
  /// URLs can't serve as the key when they change on every request (e.g. a
  /// new auth token). Null: the URL is the key.
  final String? cacheKey;

  final String? title;
  final String? artist;
  final String? album;
  final Uri? artUri;

  AudioSource.uri(this.uri,
      {this.tag,
      this.gain = 1.0,
      this.cacheKey,
      this.title,
      this.artist,
      this.album,
      this.artUri})
      : id = '${++_lastId}';

  Map<String, Object?> _toMap() => {
        'id': id,
        'uri': uri.toString(),
        'gain': gain,
        'cacheKey': cacheKey,
        'title': title,
        'artist': artist,
        'album': album,
        'artUri': artUri?.toString(),
      };
}

class VoidweaverPlayer {
  static const _plugin = MethodChannel('voidweaver_player');
  static int _lastPlayerId = 0;

  final String _id =
      '${DateTime.now().microsecondsSinceEpoch}-${++_lastPlayerId}';
  late final MethodChannel _channel = MethodChannel('voidweaver_player/$_id');
  late final Future<void> _created = _create();
  StreamSubscription? _eventSubscription;
  bool _disposed = false;

  final List<AudioSource> _sequence = [];
  final Map<String, double> _gains = {};
  PlayerState _playerState = const PlayerState(false, ProcessingState.idle);
  int? _currentIndex;
  Duration _position = Duration.zero;
  Duration? _duration;

  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();
  final _playerStateController = StreamController<PlayerState>.broadcast();
  final _indexController = StreamController<int?>.broadcast();
  final _errorController = StreamController<PlayerException>.broadcast();
  final _commandController = StreamController<SystemCommand>.broadcast();

  Future<void> _create() async {
    await _plugin.invokeMethod('create', {'id': _id});
    _eventSubscription = EventChannel('voidweaver_player/$_id/events')
        .receiveBroadcastStream()
        .listen(_onEvent);
  }

  /// Updated about every 200 ms while playing, and on every state change.
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration?> get durationStream => _durationController.stream;
  Stream<PlayerState> get playerStateStream => _playerStateController.stream;
  Stream<ProcessingState> get processingStateStream =>
      playerStateStream.map((state) => state.processingState).distinct();
  Stream<int?> get currentIndexStream => _indexController.stream;
  Stream<PlayerException> get errorStream => _errorController.stream;

  /// Commands from the notification, lock screen, Bluetooth and media
  /// buttons.
  Stream<SystemCommand> get commandStream => _commandController.stream;

  PlayerState get playerState => _playerState;
  bool get playing => _playerState.playing;
  ProcessingState get processingState => _playerState.processingState;
  int? get currentIndex => _currentIndex;
  Duration get position => _position;
  Duration? get duration => _duration;
  List<AudioSource> get sequence => List.unmodifiable(_sequence);

  void _onEvent(dynamic event) {
    if (_disposed) return;
    final map = event as Map;
    if (map['type'] == 'error') {
      _errorController.add(_exception(map));
    } else if (map['type'] == 'command') {
      final position = map['position'] as int?;
      _commandController.add(SystemCommand(
          SystemCommandType.values.byName(map['command'] as String),
          position == null ? null : Duration(milliseconds: position)));
    } else {
      _applyState(map);
    }
  }

  static PlayerException _exception(Map map) => PlayerException(
      map['code'] as int? ?? 0,
      map['message'] as String?,
      map['index'] as int?);

  void _applyState(Map? map) {
    if (map == null || _disposed) return;
    final state = PlayerState(map['playing'] as bool,
        ProcessingState.values[map['processingState'] as int]);
    final index = map['index'] as int?;
    final position = Duration(milliseconds: map['position'] as int);
    final durationMs = map['duration'] as int?;
    final duration =
        durationMs == null ? null : Duration(milliseconds: durationMs);

    if (index != _currentIndex) {
      _currentIndex = index;
      _indexController.add(index);
    }
    if (duration != _duration) {
      _duration = duration;
      _durationController.add(duration);
    }
    if (position != _position) {
      _position = position;
      _positionController.add(position);
    }
    if (state != _playerState) {
      _playerState = state;
      _playerStateController.add(state);
    }
  }

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    await _created;
    if (_disposed) return;
    _applyState(await _channel.invokeMethod<Map>(method, arguments));
  }

  /// Replaces the playlist and prepares the item at [initialIndex]. Completes
  /// once it's ready; throws a [PlayerException] if it fails to load, or a
  /// [PlayerInterruptedException] if another call replaces the playlist or
  /// stops the player first.
  Future<Duration?> setAudioSources(List<AudioSource> sources,
      {int initialIndex = 0, Duration initialPosition = Duration.zero}) async {
    _sequence
      ..clear()
      ..addAll(sources);
    _gains
      ..clear()
      ..addEntries(sources.map((s) => MapEntry(s.id, s.gain)));
    try {
      await _invoke('setAudioSources', {
        'sources': [for (final s in sources) s._toMap()],
        'initialIndex': initialIndex,
        'initialPosition': initialPosition.inMilliseconds,
      });
    } on PlatformException catch (e) {
      if (e.code == 'interrupted') throw PlayerInterruptedException(e.message);
      final details = e.details;
      if (details is Map) throw _exception(details);
      throw PlayerException(0, e.message);
    }
    return _duration;
  }

  /// The linear gain [source] plays at, applied to its samples before they
  /// are mixed: it takes effect exactly where the item starts, and can be
  /// above 1 (samples are clipped at full scale).
  double gainOf(AudioSource source) => _gains[source.id] ?? source.gain;

  /// Changes the gain of [source]. If it's playing, the change is heard
  /// within a buffer or two.
  Future<void> setGain(AudioSource source, double gain) {
    if (_gains[source.id] == gain) return Future.value();
    _gains[source.id] = gain;
    return _invoke('setGain', {'id': source.id, 'gain': gain});
  }

  /// Starts or resumes playback. Completes right away.
  Future<void> play() => _invoke('play');

  Future<void> pause() => _invoke('pause');

  /// Pauses and releases the loaded media; the player is idle afterwards.
  Future<void> stop() => _invoke('stop');

  /// Seeks to [position] within the item at [index] (default: the current
  /// one). Completes once the target is ready, or has failed to load (the
  /// error is reported on [errorStream]).
  Future<void> seek(Duration? position, {int? index}) => _invoke('seek', {
        'position': (position ?? Duration.zero).inMilliseconds,
        'index': index,
      });

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _created;
      await _eventSubscription?.cancel();
      await _plugin.invokeMethod('dispose', {'id': _id});
    } finally {
      await _positionController.close();
      await _durationController.close();
      await _playerStateController.close();
      await _indexController.close();
      await _errorController.close();
      await _commandController.close();
    }
  }
}

/// The audio cache shared by all players (Media3 `SimpleCache`, 1 GB, least
/// recently used evicted first). Items are cached while they play; [prefetch]
/// downloads ahead.
class MediaCache {
  static const _channel = MethodChannel('voidweaver_player');

  const MediaCache();

  /// Downloads [uri] completely into the cache under [key]. Downloads run one
  /// at a time. Throws if the download fails; what was downloaded stays
  /// cached and the next attempt continues from there.
  Future<void> prefetch(String key, Uri uri) =>
      _channel.invokeMethod('cache.prefetch', {'key': key, 'uri': '$uri'});

  /// Those of [keys] whose content is completely cached, in order.
  Future<List<String>> cachedKeys(List<String> keys) async =>
      (await _channel
          .invokeListMethod<String>('cache.cachedKeys', {'keys': keys})) ??
      const [];

  /// Up to [length] bytes from the start of the cached content for [key],
  /// without the network. Null if its start isn't cached.
  Future<Uint8List?> readHead(String key, int length) =>
      _channel.invokeMethod<Uint8List>(
          'cache.readHead', {'key': key, 'length': length});

  Future<int> sizeInBytes() async =>
      await _channel.invokeMethod<int>('cache.size') ?? 0;

  /// Removes everything. Downloads that are running still finish.
  Future<void> clear() => _channel.invokeMethod('cache.clear');
}
