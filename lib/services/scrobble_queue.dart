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

/// Persistent queue of scrobble requests ("now playing" and submissions),
/// sent oldest first.
///
/// subsoxy tells plays from skips by the order and times of scrobbles: a
/// "now playing" followed by another song within twice its length, without
/// a submission in between, is a skip. So every request is kept until the
/// server has it, including "now playing", and each carries the time it
/// happened (`time`: when the song started, or when the play started), which
/// subsoxy measures with when both requests have one. Requests delivered
/// late, after an offline stretch, a kill or a rejected password, are then
/// judged as if they had arrived on time: a song skipped offline still counts
/// as skipped, and one paused overnight before the next doesn't.
///
/// A request that can't be sent (offline, server down, credentials refused)
/// stays at the front and blocks the ones behind it until it goes through or
/// expires after [_maxAge]. It's retried whenever a new request is queued,
/// when the network is back ([networkAvailable]), and by a timer that only
/// runs while something is blocked: after 30 s, then at twice the delay each
/// time, up to 5 minutes. With nothing to send there's no timer, so a phone
/// playing with the screen off isn't woken for an empty queue. A request the
/// server rejects for itself (e.g. unknown song) is dropped. A generic error
/// (code 0) may be the server's trouble of the moment (a busy database, a
/// proxy that can't reach Navidrome), so that request is retried like a
/// network failure, for up to [_genericRetryWindow].
class ScrobbleQueue {
  static const String _storageKey = 'scrobble_queue';
  // How far the stored list has been sent, see _saveProgress()
  static const String _progressKey = 'scrobble_queue_sent';
  static const Duration _maxAge = Duration(days: 7); // Drop old requests
  // How long a request that fails with a generic server error is kept
  static const Duration _genericRetryWindow = Duration(hours: 1);

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
  // The request that last failed with a generic server error, and since when
  ScrobbleRequest? _genericFailing;
  DateTime? _genericFailingSince;
  // What the stored list holds (see _saveProgress()): a key of its first
  // request, and how many requests from its start are done (sent or dropped)
  // and have left [_queue]. Null while nothing is stored.
  String? _storedHead;
  int _handled = 0;

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
          // SubsonicApi.hasRejectedCredentials). They wait for a new password
          // (AppState.updatePassword() processes the queue) or the next timer
          // tick after the flag cleared.
          _log.fine('Credentials rejected, holding ${_queue.length} requests');
          blocked = true;
          break;
        }

        final request = _queue.first;

        final age = _clock().difference(request.queuedAt);
        if (age > _maxAge) {
          _log.info(
            'Dropping old scrobble request for song ${request.songId} (age: ${age.inDays} days)',
          );
          _removeFirst(request);
          continue;
        }

        var sent = false;
        try {
          await _sendScrobble(request);
          sent = true;
          _retryDelay = _initialRetryDelay;
          _genericFailing = null;
          _genericFailingSince = null;
          _log.fine(
            'Successfully sent ${request.type.name} for song ${request.songId}',
          );
        } catch (e) {
          final rejected = _isRejected(request, e);
          if (!rejected) {
            _log.warning(
              'Failed to send ${request.type.name} for song ${request.songId}, will retry',
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
        _removeFirst(request);
        if (sent && _queue.isNotEmpty) {
          // Saved right away rather than at the end of the pass: a process
          // killed during a long backlog would send every request the server
          // already has again on the next start, counting plays twice and
          // taking songs played since for skipped. (Once the queue is empty,
          // the end of the pass clears it.)
          await _saveProgress();
        }
        if (sent && request.type == ScrobbleType.submission) {
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
        // Compacts the stored list if requests have left it, see
        // _saveProgress()
        if (_handled > 0) await _saveQueue();
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

  /// Removes [request], the one at the front of the queue, which is done:
  /// sent, or dropped. Not there any more after [clear] ended the pass's
  /// work.
  void _removeFirst(ScrobbleRequest request) {
    if (_queue.isEmpty || !identical(_queue.first, request)) return;
    _queue.removeAt(0);
    _handled++;
  }

  /// Whether [request] is dropped after failing with [error], rather than
  /// kept and retried: the server refused it for itself (e.g. unknown song).
  /// Not a failure to reach the server, nor the credentials (the queue waits
  /// for a new password), nor a generic server error before
  /// [_genericRetryWindow] has passed since it first failed that way.
  bool _isRejected(ScrobbleRequest request, Object error) {
    if (error is! SubsonicException || error.isAuthError) {
      // Not "failed that way" any more: counted again from the next generic
      // error (e.g. after a stretch offline)
      _genericFailing = null;
      _genericFailingSince = null;
      return false;
    }
    if (!error.isGenericError) return true;
    if (!identical(_genericFailing, request)) {
      _genericFailing = request;
      _genericFailingSince = _clock();
    }
    return _clock().difference(_genericFailingSince!) > _genericRetryWindow;
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
        // When the song started, so a late delivery is judged by that
        await _api.scrobbleNowPlaying(
          request.songId,
          startedAt: request.queuedAt,
        );
        break;
      case ScrobbleType.submission:
        await _api.scrobbleSubmission(
          request.songId,
          playedAt: request.playedAt,
        );
        break;
    }
  }

  /// Identifies a stored request by what it says, so a stored position in the
  /// list (see [_saveProgress]) can tell the list it was written for
  static String _keyOf(Object? request) => request is Map<String, dynamic>
      ? '${request['type']}/${request['songId']}/${request['queuedAt']}/'
            '${request['playedAt']}'
      : 'unreadable';

  /// Load queue from persistent storage
  Future<void> _loadQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queueJson = prefs.getString(_storageKey);

      if (queueJson != null) {
        final queueData = json.decode(queueJson) as List<dynamic>;
        _queue.clear();
        // The requests at the start were sent already, see _saveProgress()
        final handled = _handledOf(prefs, queueData);
        _storedHead = queueData.isEmpty ? null : _keyOf(queueData.first);
        _handled = handled;
        // Entry by entry: one that can't be read (e.g. written by a newer
        // version) is dropped, not the plays around it
        var droppedUnreadable = false;
        for (final item in queueData.skip(handled)) {
          final ScrobbleRequest request;
          try {
            request = ScrobbleRequest.fromJson(item as Map<String, dynamic>);
          } catch (e) {
            _log.warning('Dropping unreadable scrobble request: $item', e);
            droppedUnreadable = true;
            continue;
          }
          _queue.add(request);
        }
        _log.fine(
          'Loaded ${_queue.length} scrobble requests from storage '
          '($handled of the stored list were sent already)',
        );
        if (_queue.isEmpty) {
          // Nothing left to send: don't leave the list for the next start
          await _clearQueue();
        } else if (droppedUnreadable) {
          // The queue is no longer the stored list from [handled] on, which
          // _saveProgress() counts on: write it as it is
          await _saveQueue();
        }
      }
    } catch (e) {
      _log.warning('Error loading scrobble queue', e);
      _queue.clear();
      _storedHead = null;
      _handled = 0;
    }
  }

  /// How many requests at the start of the stored list [stored] were sent
  /// already, from [_progressKey]; 0 if that was written for another list
  int _handledOf(SharedPreferences prefs, List<dynamic> stored) {
    final progressJson = prefs.getString(_progressKey);
    if (progressJson == null || stored.isEmpty) return 0;
    try {
      final progress = json.decode(progressJson) as Map<String, dynamic>;
      final handled = progress['handled'] as int;
      if (progress['first'] == _keyOf(stored.first) &&
          handled >= 0 &&
          handled <= stored.length) {
        return handled;
      }
    } catch (e) {
      _log.warning('Ignoring unreadable scrobble queue progress', e);
    }
    return 0;
  }

  /// Saves the whole queue, so the requests survive the process. Requests
  /// sent since the last save are gone from the stored list afterwards.
  Future<void> _saveQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_queue.isEmpty) {
        await _clearQueue();
        return;
      }
      // What is stored is worked out right before the write, so it always
      // describes what the write puts there
      final requests = [for (final request in _queue) request.toJson()];
      _storedHead = _keyOf(requests.first);
      _handled = 0;
      await prefs.setString(_storageKey, json.encode(requests));
      // Belonged to the list before
      await prefs.remove(_progressKey);
    } catch (e) {
      _log.warning('Error saving scrobble queue', e);
    }
  }

  /// Saves that the requests that have left the queue since the stored list
  /// was written are done, so a restart doesn't send them again. Writes a
  /// few bytes: Android's SharedPreferences rewrites its whole file (the
  /// settings and the saved queue too) on every change, so saving the list
  /// again after each request would make a backlog of thousands of requests
  /// (a week offline) rewrite it that many times. The list itself is written
  /// again once the pass is over ([_saveQueue]) and when a request is added.
  Future<void> _saveProgress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final head = _storedHead;
      if (head == null) {
        // Nothing stored yet (the first save is still on its way)
        await _saveQueue();
        return;
      }
      await prefs.setString(
        _progressKey,
        json.encode({'first': head, 'handled': _handled}),
      );
    } catch (e) {
      _log.warning('Error saving scrobble queue progress', e);
    }
  }

  /// Clear queue from persistent storage
  Future<void> _clearQueue() async {
    _storedHead = null;
    _handled = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_storageKey);
      await prefs.remove(_progressKey);
    } catch (e) {
      _log.warning('Error clearing scrobble queue', e);
    }
  }

  /// Get current queue size
  int get queueSize => _queue.length;

  /// Plays not yet sent to the server, without the "now playing" requests
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
