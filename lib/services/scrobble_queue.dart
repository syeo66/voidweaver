import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';
import 'subsonic_api.dart';

final _log = Logger('scrobble');

/// Type of scrobble operation
enum ScrobbleType {
  nowPlaying,
  submission,
}

/// A scrobble request that can be queued and retried
class ScrobbleRequest {
  final String songId;
  final ScrobbleType type;
  final DateTime? playedAt;
  final DateTime queuedAt;

  const ScrobbleRequest({
    required this.songId,
    required this.type,
    this.playedAt,
    required this.queuedAt,
  });

  Map<String, dynamic> toJson() => {
        'songId': songId,
        'type': type.name,
        'playedAt': playedAt?.millisecondsSinceEpoch,
        'queuedAt': queuedAt.millisecondsSinceEpoch,
      };

  factory ScrobbleRequest.fromJson(Map<String, dynamic> json) {
    return ScrobbleRequest(
      songId: json['songId'] as String,
      type: ScrobbleType.values.firstWhere((e) => e.name == json['type']),
      playedAt: json['playedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['playedAt'] as int)
          : null,
      queuedAt: DateTime.fromMillisecondsSinceEpoch(json['queuedAt'] as int),
    );
  }
}

/// Persistent queue of scrobble requests, sent oldest first.
///
/// subsoxy tells plays from skips by the order and timestamps of scrobbles,
/// so a submission that can't be sent (offline, server down, credentials
/// refused) stays at the front and blocks the ones behind it until it goes
/// through or expires after [_maxAge]. It's retried every
/// [_processingInterval] and whenever a new request is queued. A submission
/// the server rejects for itself (e.g. unknown song) is dropped, and so is a
/// "now playing" that fails: it would be stale by the time it's retried.
class ScrobbleQueue {
  static const String _storageKey = 'scrobble_queue';
  static const Duration _processingInterval = Duration(seconds: 30);
  static const Duration _maxAge = Duration(days: 7); // Drop old requests

  final SubsonicApi _api;
  final List<ScrobbleRequest> _queue = [];
  Timer? _processingTimer;
  bool _isProcessing = false;
  bool _disposed = false;

  ScrobbleQueue(this._api);

  /// Initialize the queue by loading persisted requests
  Future<void> initialize() async {
    await _loadQueue();
    _startProcessingTimer();
    _log.info(
        'ScrobbleQueue initialized with ${_queue.length} pending requests');
  }

  /// Queue a "now playing" notification
  Future<void> queueNowPlaying(String songId) async {
    await _enqueue(ScrobbleRequest(
      songId: songId,
      type: ScrobbleType.nowPlaying,
      queuedAt: DateTime.now(),
    ));
  }

  /// Queue a scrobble submission
  Future<void> queueSubmission(String songId, {DateTime? playedAt}) async {
    await _enqueue(ScrobbleRequest(
      songId: songId,
      type: ScrobbleType.submission,
      playedAt: playedAt,
      queuedAt: DateTime.now(),
    ));
  }

  /// Add a request to the queue (non-blocking)
  Future<void> _enqueue(ScrobbleRequest request) async {
    _queue.add(request);
    _log.fine(
        'Queued ${request.type.name} for song ${request.songId} (queue size: ${_queue.length})');

    // Save queue asynchronously without blocking
    unawaited(_saveQueue());

    // Try to process immediately if not already processing
    if (!_isProcessing) {
      unawaited(_processQueue());
    }
  }

  /// Sends queued requests in order until the queue is empty or a
  /// submission can't be sent.
  Future<void> _processQueue() async {
    if (_isProcessing || _queue.isEmpty || _disposed) return;

    _isProcessing = true;
    _log.fine('Processing scrobble queue (${_queue.length} requests)');

    var blocked = false;
    try {
      // Requests queued meanwhile are sent in the same pass
      while (_queue.isNotEmpty && !_disposed) {
        final request = _queue.first;

        if (DateTime.now().difference(request.queuedAt) > _maxAge) {
          _log.info(
              'Dropping old scrobble request for song ${request.songId} (age: ${DateTime.now().difference(request.queuedAt).inDays} days)');
          _queue.remove(request);
          continue;
        }

        try {
          await _sendScrobble(request);
          _log.fine(
              'Successfully sent ${request.type.name} for song ${request.songId}');
        } catch (e) {
          final rejected = e is SubsonicException && !e.isAuthError;
          if (request.type == ScrobbleType.submission && !rejected) {
            _log.warning(
                'Failed to send submission for song ${request.songId}, will retry',
                e);
            blocked = true;
            break;
          }
          _log.warning(
              'Failed to send ${request.type.name} for song ${request.songId}, dropping it',
              e);
        }
        _queue.remove(request);

        // Small delay between requests to avoid overwhelming the server
        if (_queue.isNotEmpty && !_disposed) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }

      if (_queue.isNotEmpty) {
        _log.fine(
            'Scrobble queue processing stopped (${_queue.length} requests remaining)');
        await _saveQueue();
      } else {
        _log.fine('Scrobble queue empty');
        await _clearQueue();
      }
    } finally {
      _isProcessing = false;
    }

    // Requests queued while the queue was being saved. After a failure the
    // timer retries instead, so a failing request isn't sent in a loop.
    if (!blocked && _queue.isNotEmpty && !_disposed) {
      unawaited(_processQueue());
    }
  }

  /// Send a single scrobble request to the API
  Future<void> _sendScrobble(ScrobbleRequest request) async {
    switch (request.type) {
      case ScrobbleType.nowPlaying:
        await _api.scrobbleNowPlaying(request.songId);
        break;
      case ScrobbleType.submission:
        await _api.scrobbleSubmission(request.songId,
            playedAt: request.playedAt);
        break;
    }
  }

  /// Start periodic processing timer
  void _startProcessingTimer() {
    _processingTimer?.cancel();
    _processingTimer = Timer.periodic(_processingInterval, (_) {
      if (!_disposed) {
        unawaited(_processQueue());
      }
    });
  }

  /// Load queue from persistent storage
  Future<void> _loadQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queueJson = prefs.getString(_storageKey);

      if (queueJson != null) {
        final queueData = json.decode(queueJson) as List<dynamic>;
        _queue.clear();
        _queue.addAll(queueData
            .map((item) =>
                ScrobbleRequest.fromJson(item as Map<String, dynamic>))
            .toList());
        _log.fine('Loaded ${_queue.length} scrobble requests from storage');
      }
    } catch (e) {
      _log.warning('Error loading scrobble queue', e);
      _queue.clear();
    }
  }

  /// Save queue to persistent storage
  Future<void> _saveQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queueJson =
          json.encode(_queue.map((request) => request.toJson()).toList());
      await prefs.setString(_storageKey, queueJson);
    } catch (e) {
      _log.warning('Error saving scrobble queue', e);
    }
  }

  /// Clear queue from persistent storage
  Future<void> _clearQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_storageKey);
    } catch (e) {
      _log.warning('Error clearing scrobble queue', e);
    }
  }

  /// Get current queue size
  int get queueSize => _queue.length;

  /// Manually trigger queue processing (useful for testing or when network becomes available)
  Future<void> processQueue() async {
    await _processQueue();
  }

  /// Disposes the queue and drops all pending requests, also from storage.
  /// Used on logout: the requests belong to the old server.
  Future<void> clear() async {
    dispose();
    // A pass still in progress sees the empty queue and clears storage too,
    // instead of saving the requests again.
    _queue.clear();
    await _clearQueue();
  }

  /// Dispose and cleanup resources
  void dispose() {
    _disposed = true;
    _processingTimer?.cancel();
    _processingTimer = null;
    _log.fine('ScrobbleQueue disposed');
  }
}
