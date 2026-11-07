import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  static PersistedPlaybackState? fromJson(Map<String, dynamic> json) {
    try {
      return PersistedPlaybackState(
        playlist:
            (json['playlist'] as List<dynamic>?)
                ?.map((s) => Song.fromJson(s as Map<String, dynamic>))
                .toList() ??
            [],
        currentIndex: json['currentIndex'] as int? ?? 0,
        currentPosition: Duration(
          milliseconds: json['currentPositionMs'] as int? ?? 0,
        ),
        isPlaying: json['isPlaying'] as bool? ?? false,
        lastUpdated: DateTime.fromMillisecondsSinceEpoch(
          json['lastUpdated'] as int? ?? DateTime.now().millisecondsSinceEpoch,
        ),
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
/// The queue is stored in SharedPreferences and written only when it changes.
/// The position is saved every few seconds while playing, so it lives in a
/// small file of its own (`playback_position.json`, written to a temporary
/// name and renamed): SharedPreferences on Android rewrites its whole file,
/// with the queue, the pending scrobbles and the settings, on every change.
class PlaybackPersistenceService {
  static const String _queueKey = 'playbackQueue';
  // Where the position was kept before it had a file; read when there is no
  // file yet, and removed with the next position write
  static const String _legacyPositionKey = 'playbackPosition';
  static const String _positionFileName = 'playback_position.json';
  final Duration _positionSaveInterval;
  final Directory? _directoryOverride;

  SharedPreferences? _prefs;
  Timer? _positionSaveTimer;
  PersistedPlaybackState? _pendingPositionState;

  // Writes and deletes of the position file, one after the other: they share
  // a temporary name, and a clear must come after the writes before it
  Future<void> _fileOps = Future.value();
  Future<File?>? _positionFileFuture;

  // The queue last saved; the player service replaces its playlist list
  // whenever the queue changes, so identity tells whether it needs saving.
  // Changes to a song in the list (ReplayGain read from the file) go through
  // queueChanged().
  List<Song>? _savedPlaylist;
  String? _savedPlaylistSource;
  String? _savedSourceId;

  /// [directory] holds the position file; by default the app's private
  /// storage.
  PlaybackPersistenceService({
    this._positionSaveInterval = const Duration(seconds: 5),
    @visibleForTesting Directory? directory,
  }) : _directoryOverride = directory;

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
  }

  /// The position file, or null if the app's storage can't be found. Looked
  /// up on first use, so a failure only costs the position, not the start.
  Future<File?> _positionFile() => _positionFileFuture ??= () async {
    try {
      final directory =
          _directoryOverride ?? await getApplicationSupportDirectory();
      await directory.create(recursive: true);
      return File('${directory.path}/$_positionFileName');
    } catch (e) {
      _log.warning('No storage for the playback position', e);
      return null;
    }
  }();

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
          }),
        );
        _savedPlaylist = state.playlist;
        _savedPlaylistSource = state.playlistSource;
        _savedSourceId = state.sourceId;
        _log.fine('Saved playback queue: ${state.playlist.length} songs');
      }
    } catch (e) {
      _log.warning('Failed to save the playback queue', e);
    }
    await _writePosition(state);
  }

  Future<void> _writePosition(PersistedPlaybackState state) {
    final json = jsonEncode({
      'currentIndex': state.currentIndex,
      'currentPositionMs': state.currentPosition.inMilliseconds,
      'isPlaying': state.isPlaying,
      'lastUpdated': state.lastUpdated.millisecondsSinceEpoch,
    });
    return _inFileOrder(() async {
      final file = await _positionFile();
      if (file == null) return;
      try {
        // A crash mid-write can't leave a truncated file
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(json);
        await temp.rename(file.path);
        // The position moved out of SharedPreferences; this rewrites its file
        // once, after the first save by this version
        if (_prefs!.containsKey(_legacyPositionKey)) {
          await _prefs!.remove(_legacyPositionKey);
        }
      } catch (e) {
        _log.warning('Failed to save the playback position', e);
      }
    });
  }

  Future<void> _inFileOrder(Future<void> Function() operation) {
    final result = _fileOps.then((_) => operation());
    _fileOps = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<PersistedPlaybackState?> loadPlaybackState() async {
    if (_prefs == null) {
      _log.warning('SharedPreferences not initialized');
      return null;
    }

    try {
      final queue = _prefs!.getString(_queueKey);
      if (queue == null) {
        _log.fine('No saved playback state found');
        return null;
      }
      // Without a readable position the queue still comes back, from its
      // first song
      final position = await _readPosition() ?? <String, dynamic>{};

      final state = PersistedPlaybackState.fromJson({
        ...jsonDecode(queue) as Map<String, dynamic>,
        ...position,
      });

      if (state != null) {
        _log.fine(
          'Loaded playback state: ${state.playlist.length} songs, index ${state.currentIndex}',
        );
      }

      return state;
    } catch (e) {
      _log.warning('Failed to load playback state', e);
      return null;
    }
  }

  /// The saved position as JSON, from the file or, for a state saved by an
  /// earlier version, from SharedPreferences. Null if there is none, or it
  /// can't be read.
  Future<Map<String, dynamic>?> _readPosition() async {
    // After writes still in progress
    await _fileOps;
    try {
      final file = await _positionFile();
      if (file != null && await file.exists()) {
        return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      }
    } catch (e) {
      _log.warning('Failed to read the playback position', e);
    }
    try {
      final legacy = _prefs!.getString(_legacyPositionKey);
      if (legacy != null) return jsonDecode(legacy) as Map<String, dynamic>;
    } catch (e) {
      _log.warning('Failed to read the saved playback position', e);
    }
    return null;
  }

  /// A song in the saved queue's list was replaced in place (ReplayGain
  /// read from its file), so the next save writes the queue again rather
  /// than only the position.
  void queueChanged() {
    _savedPlaylist = null;
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
    _savedPlaylist = null;
    final prefs = _prefs;
    if (prefs != null) {
      try {
        for (final key in [_queueKey, _legacyPositionKey]) {
          await prefs.remove(key);
        }
      } catch (e) {
        _log.warning('Failed to clear playback state', e);
      }
    }
    // After the writes in progress, so none lands after the clear
    await _inFileOrder(() async {
      try {
        final file = await _positionFile();
        if (file != null && await file.exists()) await file.delete();
      } catch (e) {
        _log.warning('Failed to clear the playback position', e);
      }
    });
    _log.info('Cleared saved playback state');
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
