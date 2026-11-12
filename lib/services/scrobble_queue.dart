import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';

import 'subsonic_api.dart';

final _log = Logger('scrobble');

/// Type of scrobble operation
enum ScrobbleType { nowPlaying, submission }

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
/// through or expires after [_maxAge]. It's retried whenever a new request is
/// queued, when the network is back ([networkAvailable]), and by a timer that
/// only runs while something is blocked: after 30 s, then at twice the delay
/// each time, up to 5 minutes. With nothing to send there's no timer, so a
/// phone playing with the screen off isn't woken for an empty queue. A submission
/// the server rejects for itself (e.g. unknown song) is dropped, and so is a
/// "now playing" that fails: it would be stale by the time it's retried.
/// For the same reason only submissions are saved: a "now playing" from the
/// last session would mark a song as playing that isn't.
class ScrobbleQueue {
  static const String _storageKey = 'scrobble_queue';
  static const Duration _maxAge = Duration(days: 7); // Drop old requests

  final SubsonicApi _api;

  /// Called after the server accepted a submission, i.e. after a play was
  /// counted there.
  final void Function()? onSubmitted;
  final Duration _initialRetryDelay;
  final Duration _maxRetryDelay;
  final DateTime Function() _clock;
  final List<ScrobbleRequest> _queue = [];
  // Set while a submission is waiting to be sent again
  Timer? _retryTimer;
  late Duration _retryDelay = _initialRetryDelay;
  bool _isProcessing = false;
  bool _disposed = false;

  ScrobbleQueue(
    this._api, {
    this.onSubmitted,
    @visibleForTesting this._initialRetryDelay = const Duration(seconds: 30),
    @visibleForTesting this._maxRetryDelay = const Duration(minutes: 5),
    @visibleForTesting this._clock = DateTime.now,
  });

  /// Initialize the queue by loading persisted requests
  Future<void> initialize() async {
    await _loadQueue();
    _log.info(
      'ScrobbleQueue initialized with ${_queue.length} pending requests',
    );
    // Plays left from the last session, or from a login whose password the
    // server rejected, go out now
    unawaited(_processQueue());
  }

  /// Queue a "now playing" notification
  Future<void> queueNowPlaying(String songId) async {
    await _enqueue(
      ScrobbleRequest(
        songId: songId,
        type: ScrobbleType.nowPlaying,
        queuedAt: _clock(),
      ),
    );
  }

  /// Queue a scrobble submission
  Future<void> queueSubmission(String songId, {DateTime? playedAt}) async {
    await _enqueue(
      ScrobbleRequest(
        songId: songId,
        type: ScrobbleType.submission,
        playedAt: playedAt,
        queuedAt: _clock(),
      ),
    );
  }

  /// Add a request to the queue (non-blocking)
  Future<void> _enqueue(ScrobbleRequest request) async {
    _queue.add(request);
    _log.fine(
      'Queued ${request.type.name} for song ${request.songId} (queue size: ${_queue.length})',
    );

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
        if (_api.hasRejectedCredentials) {
          // Not sent: the server would refuse them (see
          // SubsonicApi.hasRejectedCredentials). As if they had been: the
          // "now playing" requests are dropped, the submissions wait for a
          // new password (AppState.updatePassword() processes the queue) or
          // the next timer tick after the flag cleared.
          _queue.removeWhere((r) => r.type == ScrobbleType.nowPlaying);
          _log.fine(
            'Credentials rejected, holding ${_queue.length} submissions',
          );
          blocked = true;
          break;
        }

        final request = _queue.first;

        final age = _clock().difference(request.queuedAt);
        if (age > _maxAge) {
          _log.info(
            'Dropping old scrobble request for song ${request.songId} (age: ${age.inDays} days)',
          );
          _queue.remove(request);
          continue;
        }

        var sent = false;
        try {
          await _sendScrobble(request);
          sent = true;
          _retryDelay = _initialRetryDelay;
          _log.fine(
            'Successfully sent ${request.type.name} for song ${request.songId}',
          );
        } catch (e) {
          final rejected = e is SubsonicException && !e.isAuthError;
          if (request.type == ScrobbleType.submission && !rejected) {
            _log.warning(
              'Failed to send submission for song ${request.songId}, will retry',
              e,
            );
            blocked = true;
            break;
          }
          _log.warning(
            'Failed to send ${request.type.name} for song ${request.songId}, dropping it',
            e,
          );
        }
        _queue.remove(request);
        if (sent && request.type == ScrobbleType.submission) {
          // Saved right away rather than at the end of the pass: a process
          // killed during a long backlog would send every play the server
          // already counted again on the next start
          await _saveQueue();
          onSubmitted?.call();
        }

        // Small delay between requests to avoid overwhelming the server
        if (_queue.isNotEmpty && !_disposed) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      if (_queue.isNotEmpty) {
        _log.fine(
          'Scrobble queue processing stopped (${_queue.length} requests remaining)',
        );
        await _saveQueue();
      } else {
        _log.fine('Scrobble queue empty');
        await _clearQueue();
      }
    } finally {
      _isProcessing = false;
    }

    if (blocked) {
      // Not sent in a loop: the timer retries, at longer intervals
      _scheduleRetry();
    } else {
      _cancelRetry();
      // Requests queued while the queue was being saved
      if (_queue.isNotEmpty && !_disposed) unawaited(_processQueue());
    }
  }

  /// Sends the blocked submission again after the current delay, which
  /// doubles up to the maximum for the next time.
  void _scheduleRetry() {
    if (_disposed) return;
    _retryTimer?.cancel();
    final delay = _retryDelay;
    _retryDelay = delay * 2 > _maxRetryDelay ? _maxRetryDelay : delay * 2;
    _log.fine('Retrying the scrobble queue in ${delay.inSeconds} s');
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(_processQueue());
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryDelay = _initialRetryDelay;
  }

  /// The network is back (see `AudioCache.networkAvailable`): a blocked
  /// submission is sent now, rather than when its timer fires, and the next
  /// failure starts from the shortest delay again.
  void networkAvailable() {
    if (_disposed || _queue.isEmpty) return;
    _cancelRetry();
    unawaited(_processQueue());
  }

  /// Whether a blocked submission is waiting for its next attempt
  @visibleForTesting
  bool get retryScheduled => _retryTimer != null;

  /// Send a single scrobble request to the API
  Future<void> _sendScrobble(ScrobbleRequest request) async {
    switch (request.type) {
      case ScrobbleType.nowPlaying:
        await _api.scrobbleNowPlaying(request.songId);
        break;
      case ScrobbleType.submission:
        await _api.scrobbleSubmission(
          request.songId,
          playedAt: request.playedAt,
        );
        break;
    }
  }

  /// Load queue from persistent storage
  Future<void> _loadQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queueJson = prefs.getString(_storageKey);

      if (queueJson != null) {
        final queueData = json.decode(queueJson) as List<dynamic>;
        _queue.clear();
        // Entry by entry: one that can't be read (e.g. written by a newer
        // version) is dropped, not the plays around it
        for (final item in queueData) {
          final ScrobbleRequest request;
          try {
            request = ScrobbleRequest.fromJson(item as Map<String, dynamic>);
          } catch (e) {
            _log.warning('Dropping unreadable scrobble request: $item', e);
            continue;
          }
          // Saved by older versions; stale now
          if (request.type == ScrobbleType.submission) _queue.add(request);
        }
        _log.fine('Loaded ${_queue.length} scrobble requests from storage');
      }
    } catch (e) {
      _log.warning('Error loading scrobble queue', e);
      _queue.clear();
    }
  }

  /// Saves the submissions in the queue; "now playing" requests aren't kept
  /// across sessions
  Future<void> _saveQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final submissions = [
        for (final request in _queue)
          if (request.type == ScrobbleType.submission) request.toJson(),
      ];
      if (submissions.isEmpty) {
        await prefs.remove(_storageKey);
        return;
      }
      await prefs.setString(_storageKey, json.encode(submissions));
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

  /// Plays not yet sent to the server. Without the "now playing" requests,
  /// which are dropped rather than retried anyway.
  int get pendingSubmissions =>
      _queue.where((r) => r.type == ScrobbleType.submission).length;

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
    _retryTimer?.cancel();
    _retryTimer = null;
    _log.fine('ScrobbleQueue disposed');
  }
}
