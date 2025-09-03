import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'subsonic_api.dart';

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
        currentIndex: json['currentIndex'] ?? 0,
        currentPosition: Duration(milliseconds: json['currentPositionMs'] ?? 0),
        isPlaying: json['isPlaying'] ?? false,
        lastUpdated: DateTime.fromMillisecondsSinceEpoch(
            json['lastUpdated'] ?? DateTime.now().millisecondsSinceEpoch),
        playlistSource: json['playlistSource'],
        sourceId: json['sourceId'],
      );
    } catch (e) {
      debugPrint('Failed to deserialize PlaybackState: $e');
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

class PlaybackPersistenceService {
  static const String _playbackStateKey = 'playbackState';
  static const Duration _positionSaveInterval = Duration(seconds: 5);

  SharedPreferences? _prefs;
  Timer? _positionSaveTimer;

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
  }

  Future<void> savePlaybackState(PersistedPlaybackState state) async {
    if (_prefs == null) {
      debugPrint('SharedPreferences not initialized');
      return;
    }

    try {
      final json = jsonEncode(state.toJson());
      await _prefs!.setString(_playbackStateKey, json);
      debugPrint(
          'Saved playback state: ${state.playlist.length} songs, index ${state.currentIndex}');
    } catch (e) {
      debugPrint('Failed to save playback state: $e');
    }
  }

  Future<PersistedPlaybackState?> loadPlaybackState() async {
    if (_prefs == null) {
      debugPrint('SharedPreferences not initialized');
      return null;
    }

    try {
      final json = _prefs!.getString(_playbackStateKey);
      if (json == null) {
        debugPrint('No saved playback state found');
        return null;
      }

      final map = jsonDecode(json) as Map<String, dynamic>;
      final state = PersistedPlaybackState.fromJson(map);

      if (state != null) {
        debugPrint(
            'Loaded playback state: ${state.playlist.length} songs, index ${state.currentIndex}');
      }

      return state;
    } catch (e) {
      debugPrint('Failed to load playback state: $e');
      return null;
    }
  }

  void schedulePositionSave(PersistedPlaybackState state) {
    _positionSaveTimer?.cancel();
    _positionSaveTimer = Timer(_positionSaveInterval, () {
      savePlaybackState(state);
    });
  }

  Future<void> clearPlaybackState() async {
    if (_prefs == null) return;

    try {
      await _prefs!.remove(_playbackStateKey);
      debugPrint('Cleared saved playback state');
    } catch (e) {
      debugPrint('Failed to clear playback state: $e');
    }
  }

  void dispose() {
    _positionSaveTimer?.cancel();
  }
}
