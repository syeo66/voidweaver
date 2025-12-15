import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'subsonic_api.dart';

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
  final int retryCount;

  const ScrobbleRequest({
    required this.songId,
    required this.type,
    this.playedAt,
    required this.queuedAt,
    this.retryCount = 0,
  });

  Map<String, dynamic> toJson() => {
        'songId': songId,
        'type': type.name,
        'playedAt': playedAt?.millisecondsSinceEpoch,
        'queuedAt': queuedAt.millisecondsSinceEpoch,
        'retryCount': retryCount,
      };

  factory ScrobbleRequest.fromJson(Map<String, dynamic> json) {
    return ScrobbleRequest(
      songId: json['songId'] as String,
      type: ScrobbleType.values.firstWhere((e) => e.name == json['type']),
      playedAt: json['playedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['playedAt'] as int)
          : null,
      queuedAt: DateTime.fromMillisecondsSinceEpoch(json['queuedAt'] as int),
      retryCount: json['retryCount'] as int? ?? 0,
    );
  }

  ScrobbleRequest copyWithRetry() => ScrobbleRequest(
        songId: songId,
        type: type,
        playedAt: playedAt,
        queuedAt: queuedAt,
        retryCount: retryCount + 1,
      );
}

/// Service for managing a persistent queue of scrobble requests
/// Handles network failures gracefully by queuing and retrying scrobbles
class ScrobbleQueue {
  static const String _storageKey = 'scrobble_queue';
  static const int _maxRetries = 5;
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
    debugPrint(
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
    debugPrint(
        'Queued ${request.type.name} for song ${request.songId} (queue size: ${_queue.length})');

    // Save queue asynchronously without blocking
    unawaited(_saveQueue());

    // Try to process immediately if not already processing
    if (!_isProcessing) {
      unawaited(_processQueue());
    }
  }

  /// Process all pending scrobble requests
  Future<void> _processQueue() async {
    if (_isProcessing || _queue.isEmpty || _disposed) return;

    _isProcessing = true;
    debugPrint('Processing scrobble queue (${_queue.length} requests)');

    final requestsToProcess = List<ScrobbleRequest>.from(_queue);
    final successfulRequests = <ScrobbleRequest>[];
    final failedRequests = <ScrobbleRequest>[];

    for (final request in requestsToProcess) {
      if (_disposed) break;

      // Skip requests that are too old
      if (DateTime.now().difference(request.queuedAt) > _maxAge) {
        debugPrint(
            'Dropping old scrobble request for song ${request.songId} (age: ${DateTime.now().difference(request.queuedAt).inDays} days)');
        successfulRequests.add(request);
        continue;
      }

      // Skip requests that have exceeded retry limit
      if (request.retryCount >= _maxRetries) {
        debugPrint(
            'Dropping scrobble request for song ${request.songId} (max retries exceeded)');
        successfulRequests.add(request);
        continue;
      }

      try {
        await _sendScrobble(request);
        successfulRequests.add(request);
        debugPrint(
            'Successfully sent ${request.type.name} for song ${request.songId}');
      } catch (e) {
        debugPrint(
            'Failed to send ${request.type.name} for song ${request.songId}: $e');
        // Re-queue with incremented retry count
        failedRequests.add(request.copyWithRetry());
      }

      // Small delay between requests to avoid overwhelming the server
      if (!_disposed) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    // Update queue: remove only the processed requests, keep items added during processing
    // and failed ones with updated retry counts
    for (final request in requestsToProcess) {
      _queue.remove(request);
    }
    _queue.addAll(failedRequests);

    if (_queue.isNotEmpty) {
      debugPrint(
          'Scrobble queue processing complete (${_queue.length} requests remaining)');
      await _saveQueue();
    } else {
      debugPrint('Scrobble queue empty');
      await _clearQueue();
    }

    _isProcessing = false;

    // If there are still items in the queue, process them
    if (_queue.isNotEmpty && !_disposed) {
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
        final List<dynamic> queueData = json.decode(queueJson);
        _queue.clear();
        _queue.addAll(
            queueData.map((item) => ScrobbleRequest.fromJson(item)).toList());
        debugPrint('Loaded ${_queue.length} scrobble requests from storage');
      }
    } catch (e) {
      debugPrint('Error loading scrobble queue: $e');
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
      debugPrint('Error saving scrobble queue: $e');
    }
  }

  /// Clear queue from persistent storage
  Future<void> _clearQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_storageKey);
    } catch (e) {
      debugPrint('Error clearing scrobble queue: $e');
    }
  }

  /// Get current queue size
  int get queueSize => _queue.length;

  /// Check if queue is currently processing
  bool get isProcessing => _isProcessing;

  /// Manually trigger queue processing (useful for testing or when network becomes available)
  Future<void> processQueue() async {
    await _processQueue();
  }

  /// Dispose and cleanup resources
  void dispose() {
    _disposed = true;
    _processingTimer?.cancel();
    _processingTimer = null;
    debugPrint('ScrobbleQueue disposed');
  }
}
