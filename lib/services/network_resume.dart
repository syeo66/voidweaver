import 'dart:async';

import 'package:logging/logging.dart';
import 'package:voidweaver_player/voidweaver_player.dart';

final _log = Logger('audio_player');

/// Plays a track again, where it broke off, once the network is back, if it
/// stopped because the network failed while it was meant to play. Armed by
/// the service when a move fails for the network ([arm]); cleared by every
/// move, `pause()`, `stop()` and `dispose()` ([clear]). See
/// docs/PLAYBACK.md#load-errors.
class NetworkResume {
  /// How long after a network failure the network coming back still resumes
  /// playback. Media3 keeps the service in the foreground for 10 minutes
  /// after playback stops, so the app can still start playing from the
  /// background; later the user may have long moved on.
  static const window = Duration(minutes: 10);

  final NetworkResumeHost _host;
  final DateTime Function() _clock;

  // Playback stopped on a track because the network failed while it was
  // meant to play: it's played again when the network is back, see
  // onNetworkAvailable(). (A move after the failure loads the queue, as the
  // player is idle, which takes a new generation: onNetworkAvailable()
  // checks that as well.)
  ({int generation, int index, DateTime failedAt})? _armed;

  NetworkResume(this._host, {this._clock = DateTime.now});

  /// Whether [failure] is the player failing to reach the server (the
  /// connection failed, broke off or timed out), as opposed to the server
  /// answering with an error (Media3 code 2004), or with a document instead
  /// of audio (2000, see `LoadErrorPolicy`), which it would answer again.
  static bool isNetworkFailure(Object failure) =>
      failure is PlayerException &&
      (failure.code == 2001 || // ERROR_CODE_IO_NETWORK_CONNECTION_FAILED
          failure.code == 2002); // ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT

  /// Playback stopped on the track at [index] of the playlist's
  /// [generation] because the network failed: plays it again when the
  /// network is back.
  void arm({required int generation, required int index}) {
    _armed = (generation: generation, index: index, failedAt: _clock());
  }

  /// Nothing is resumed when the network comes back: the user did something
  /// with playback since.
  void clear() => _armed = null;

  /// The network is back: plays the track that stopped because the network
  /// failed, where it broke off, unless the user did anything with playback
  /// since, or it's been too long.
  void onNetworkAvailable() {
    final resume = _armed;
    if (resume == null || _host.isDisposed) return;
    _armed = null;
    if (_clock().difference(resume.failedAt) > window) {
      _log.info('Network is back, too long after playback stopped to resume');
      return;
    }
    if (resume.generation != _host.generation ||
        resume.index != _host.currentIndex ||
        _host.hasMove ||
        !_host.needsLoad) {
      return;
    }
    _log.info('Network is back, resuming index ${_host.currentIndex}');
    unawaited(_host.play());
  }
}

/// What [NetworkResume] needs from the service it works for: where playback
/// is, and playing it.
abstract interface class NetworkResumeHost {
  /// Whether the service has been disposed
  bool get isDisposed;

  /// The generation of the playlist, see `PlayerWorker.generation`
  int get generation;

  /// The playlist position the app shows as current
  int get currentIndex;

  /// Whether a move (a load or a skip) is in progress
  bool get hasMove;

  /// Whether the next play() loads the queue again, see
  /// `AudioPlayerService.needsSourceReload`
  bool get needsLoad;

  /// Plays the current track
  Future<void> play();
}
