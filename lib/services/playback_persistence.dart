import 'dart:convert';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';
import 'subsonic_api.dart';

final _log = Logger('playback_persistence');

class PersistedPlaybackState {
  final List<Song> playlist;
  final int currentIndex;
  final Duration currentPosition;
  final bool isPlaying;
  final DateTime lastUpdated;
  final String? playlistSource;
  final String? sourceId;

  const PersistedPlaybackState({
    required this.playlist,
    required this.currentIndex,
    required this.currentPosition,
    required this.isPlaying,
    required this.lastUpdated,
    this.playlistSource,
    this.sourceId,
  });

  Map<String, dynamic> toJson() {
    return {
      'playlist': playlist.map((s) => s.toJson()).toList(),
      'currentIndex': currentIndex,
      'currentPositionMs': currentPosition.inMilliseconds,
      'isPlaying': isPlaying,
      'lastUpdated': lastUpdated.millisecondsSinceEpoch,
      'playlistSource': playlistSource,
      'sourceId': sourceId,
    };
  }

  static PersistedPlaybackState? fromJson(Map<String, dynamic> json) {
    try {
      return PersistedPlaybackState(
        playlist: (json['playlist'] as List<dynamic>?)
                ?.map((s) => Song.fromJson(s as Map<String, dynamic>))
                .toList() ??
            [],
        currentIndex: json['currentIndex'] as int? ?? 0,
        currentPosition:
            Duration(milliseconds: json['currentPositionMs'] as int? ?? 0),
        isPlaying: json['isPlaying'] as bool? ?? false,
        lastUpdated: DateTime.fromMillisecondsSinceEpoch(
            json['lastUpdated'] as int? ??
                DateTime.now().millisecondsSinceEpoch),
        playlistSource: json['playlistSource'] as String?,
        sourceId: json['sourceId'] as String?,
      );
    } catch (e) {
      _log.warning('Failed to deserialize PlaybackState', e);
      return null;
    }
  }

  PersistedPlaybackState copyWith({
    List<Song>? playlist,
    int? currentIndex,
    Duration? currentPosition,
    bool? isPlaying,
    DateTime? lastUpdated,
    String? playlistSource,
    String? sourceId,
  }) {
    return PersistedPlaybackState(
      playlist: playlist ?? this.playlist,
      currentIndex: currentIndex ?? this.currentIndex,
      currentPosition: currentPosition ?? this.currentPosition,
      isPlaying: isPlaying ?? this.isPlaying,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      playlistSource: playlistSource ?? this.playlistSource,
      sourceId: sourceId ?? this.sourceId,
    );
  }

  bool get isEmpty => playlist.isEmpty;
  bool get hasValidIndex => currentIndex >= 0 && currentIndex < playlist.length;
  Song? get currentSong => hasValidIndex ? playlist[currentIndex] : null;
}

/// Saves the queue and the playback position, so they're restored on the
/// next start.
///
/// The queue and the position are stored under separate keys: the position is
/// saved every few seconds while playing, and SharedPreferences on Android
/// rewrites its whole file on every change, so those saves leave out the
/// queue unless it changed.
class PlaybackPersistenceService {
  static const String _queueKey = 'playbackQueue';
  static const String _positionKey = 'playbackPosition';
  // Queue and position together, as saved by older versions
  static const String _legacyKey = 'playbackState';
  final Duration _positionSaveInterval;

  SharedPreferences? _prefs;
  Timer? _positionSaveTimer;
  PersistedPlaybackState? _pendingPositionState;

  // The queue last saved; the player service replaces its playlist list
  // whenever the queue changes, so identity tells whether it needs saving
  List<Song>? _savedPlaylist;
  String? _savedPlaylistSource;
  String? _savedSourceId;

  PlaybackPersistenceService({
    Duration positionSaveInterval = const Duration(seconds: 5),
  }) : _positionSaveInterval = positionSaveInterval;

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
  }

  Future<void> savePlaybackState(PersistedPlaybackState state) async {
    // An explicit save supersedes any pending position save, which would
    // otherwise overwrite it with older state when its timer fires.
    _cancelPendingPositionSave();
    await _writePlaybackState(state);
  }

  Future<void> _writePlaybackState(PersistedPlaybackState state) async {
    if (_prefs == null) {
      _log.warning('SharedPreferences not initialized');
      return;
    }

    try {
      if (!identical(state.playlist, _savedPlaylist) ||
          state.playlistSource != _savedPlaylistSource ||
          state.sourceId != _savedSourceId) {
        await _prefs!.setString(
            _queueKey,
            jsonEncode({
              'playlist': state.playlist.map((s) => s.toJson()).toList(),
              'playlistSource': state.playlistSource,
              'sourceId': state.sourceId,
            }));
        _savedPlaylist = state.playlist;
        _savedPlaylistSource = state.playlistSource;
        _savedSourceId = state.sourceId;
        if (_prefs!.containsKey(_legacyKey)) await _prefs!.remove(_legacyKey);
        _log.fine('Saved playback queue: ${state.playlist.length} songs');
      }
      await _prefs!.setString(
          _positionKey,
          jsonEncode({
            'currentIndex': state.currentIndex,
            'currentPositionMs': state.currentPosition.inMilliseconds,
            'isPlaying': state.isPlaying,
            'lastUpdated': state.lastUpdated.millisecondsSinceEpoch,
          }));
    } catch (e) {
      _log.warning('Failed to save playback state', e);
    }
  }

  Future<PersistedPlaybackState?> loadPlaybackState() async {
    if (_prefs == null) {
      _log.warning('SharedPreferences not initialized');
      return null;
    }

    try {
      final queue = _prefs!.getString(_queueKey);
      final position = _prefs!.getString(_positionKey);
      final Map<String, dynamic> map;
      if (queue != null && position != null) {
        map = {
          ...jsonDecode(queue) as Map<String, dynamic>,
          ...jsonDecode(position) as Map<String, dynamic>,
        };
      } else if (_prefs!.getString(_legacyKey) case final legacy?) {
        map = jsonDecode(legacy) as Map<String, dynamic>;
      } else {
        _log.fine('No saved playback state found');
        return null;
      }

      final state = PersistedPlaybackState.fromJson(map);

      if (state != null) {
        _log.fine(
            'Loaded playback state: ${state.playlist.length} songs, index ${state.currentIndex}');
      }

      return state;
    } catch (e) {
      _log.warning('Failed to load playback state', e);
      return null;
    }
  }

  /// Saves [state] at most once per interval. Called on every position
  /// update, so the timer must not be restarted on each call or it would
  /// never fire during continuous playback.
  void schedulePositionSave(PersistedPlaybackState state) {
    _pendingPositionState = state;
    if (_positionSaveTimer?.isActive ?? false) return;

    _positionSaveTimer = Timer(_positionSaveInterval, () {
      final pending = _pendingPositionState;
      _pendingPositionState = null;
      if (pending != null) unawaited(_writePlaybackState(pending));
    });
  }

  void _cancelPendingPositionSave() {
    _positionSaveTimer?.cancel();
    _positionSaveTimer = null;
    _pendingPositionState = null;
  }

  Future<void> clearPlaybackState() async {
    _cancelPendingPositionSave();
    if (_prefs == null) return;

    try {
      _savedPlaylist = null;
      for (final key in [_queueKey, _positionKey, _legacyKey]) {
        await _prefs!.remove(key);
      }
      _log.info('Cleared saved playback state');
    } catch (e) {
      _log.warning('Failed to clear playback state', e);
    }
  }

  /// Writes a position save that's waiting for its timer right away.
  void flushPendingPositionSave() {
    final pending = _pendingPositionState;
    _cancelPendingPositionSave();
    if (pending != null) unawaited(_writePlaybackState(pending));
  }

  /// Writes a pending position save instead of dropping it.
  void dispose() {
    flushPendingPositionSave();
  }
}
