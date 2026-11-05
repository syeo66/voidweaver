import 'dart:async';

import 'package:logging/logging.dart';

import 'audio_cache.dart';
import 'replaygain_debug_logger.dart';
import 'replaygain_reader.dart';
import 'subsonic_api.dart';

final _log = Logger('upcoming_downloads');

/// Downloads the tracks after the current one to the audio cache while
/// playing, so playback can continue if the network drops; the player plays
/// them from there. See docs/CACHING.md.
///
/// Downloads run one at a time, nearest track first, so the next song is
/// ready as early as possible. A failed download (e.g. the network dropped
/// for a moment) is tried again a few times, and the run starts again when
/// the network comes back ([networkAvailable]). Otherwise the player would
/// have to stream the track when it gets there, and a network drop at that
/// moment stops playback.
class UpcomingDownloads {
  /// Upcoming tracks downloaded while playing
  static const int maxTracks = 3;

  /// Retries of a failed download. The delay before each retry doubles: with
  /// the default 5 s, that is 5 s, 10 s, ... about 2.5 minutes in all.
  static const int maxRetries = 5;

  final AudioCache _audioCache;
  final SubsonicApi _api;
  final Duration _retryDelay;
  final void Function(List<Song> playlist, int index, ReplayGainData data)
  _onReplayGain;

  // Incremented whenever downloads start; an older run stops
  int _run = 0;

  // The download in progress, see _cancelUnwanted()
  _Download? _inFlight;

  // The current run, once one of its downloads failed: it's waiting to try
  // again, or gave up. networkAvailable() starts it again.
  _Run? _failedRun;

  /// [onReplayGain] gets the ReplayGain data read from a downloaded file of
  /// a song the server sent none for.
  UpcomingDownloads({
    required this._audioCache,
    required this._api,
    required this._retryDelay,
    required this._onReplayGain,
  });

  /// Downloads the tracks of [playlist] from [firstIndex] on, up to
  /// [maxTracks]. Replaces a run that is still going. Its download in
  /// progress is cancelled unless it's one of this run's tracks: downloads
  /// run one at a time, so the new ones would wait for it.
  ///
  /// Stops once [isCurrent] returns false (the playlist was replaced, the
  /// player went away), another run started (another track began, which
  /// starts its own downloads), or the server refused the credentials (see
  /// [SubsonicApi.hasRejectedCredentials]; the caller starts the downloads
  /// again with the new password).
  Future<void> start(
    List<Song> playlist,
    int firstIndex, {
    required bool Function() isCurrent,
  }) async {
    final run = ++_run;
    _failedRun = null;
    final end = (firstIndex + maxTracks).clamp(0, playlist.length);
    _cancelUnwanted(playlist, firstIndex, end);
    if (firstIndex >= end) return;

    bool current() =>
        run == _run && isCurrent() && !_api.hasRejectedCredentials;

    for (var index = firstIndex; index < end; index++) {
      var delay = _retryDelay;
      for (var attempt = 0; current(); attempt++) {
        if (await _download(playlist, index)) break;
        if (run == _run) {
          _failedRun = _Run(playlist, firstIndex, isCurrent);
        }
        if (attempt == maxRetries) break;
        _log.fine(() => 'Retrying "${playlist[index].title}" in $delay');
        await Future<void>.delayed(delay);
        delay *= 2;
      }
      if (!current()) break;
    }
  }

  /// The network is back (see [AudioCache.networkAvailable]). Starts the
  /// current run again if one of its downloads failed, rather than waiting
  /// for its next retry, or for the next track if it gave up: a drop longer
  /// than the retries would otherwise leave the next tracks uncached while
  /// the network is up again. Tracks it got stay cached and are skipped.
  void networkAvailable() {
    final failed = _failedRun;
    if (failed == null || !failed.isCurrent()) return;
    _log.info('Network available, downloading the next tracks again');
    unawaited(
      start(failed.playlist, failed.firstIndex, isCurrent: failed.isCurrent),
    );
  }

  /// Stops the run in progress, and cancels its download.
  void cancel() {
    _run++;
    _failedRun = null;
    _cancelUnwanted(const [], 0, 0);
  }

  /// Cancels the download in progress unless it's of [playlist] at an index
  /// from [start] to before [end]. Then it's wanted: the new run would only
  /// start it again.
  void _cancelUnwanted(List<Song> playlist, int start, int end) {
    final inFlight = _inFlight;
    if (inFlight == null) return;
    if (identical(inFlight.playlist, playlist) &&
        inFlight.index >= start &&
        inFlight.index < end) {
      return;
    }
    _inFlight = null;
    final song = inFlight.playlist[inFlight.index];
    _log.fine(() => 'Cancelling the download of "${song.title}"');
    unawaited(_audioCache.cancelDownload(song));
  }

  /// Downloads the track at [index] and reads its ReplayGain metadata from
  /// the cache if the server didn't provide it. Returns whether the track is
  /// completely cached.
  Future<bool> _download(List<Song> playlist, int index) async {
    final song = playlist[index];
    final download = _Download(playlist, index);
    _inFlight = download;
    final bool cached;
    try {
      cached = await _audioCache.prefetch(song, _api.getStreamUrl(song.id));
    } finally {
      if (identical(_inFlight, download)) _inFlight = null;
    }
    if (!cached) return false;
    if (song.replayGainTrackGain != null || song.replayGainAlbumGain != null) {
      return true;
    }
    final data = await _audioCache.readReplayGain(song);
    if (data == null) return true;
    logReplayGain(
      () =>
          '[ReplayGain] Preload read "${song.title}": Track=${data.trackGain}, Album=${data.albumGain}',
    );
    _onReplayGain(playlist, index, data);
    return true;
  }
}

/// The arguments of a [UpcomingDownloads.start] call.
class _Run {
  final List<Song> playlist;
  final int firstIndex;
  final bool Function() isCurrent;

  _Run(this.playlist, this.firstIndex, this.isCurrent);
}

/// A download of the song at [index] in [playlist].
class _Download {
  final List<Song> playlist;
  final int index;

  _Download(this.playlist, this.index);
}
