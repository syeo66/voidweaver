import 'dart:async';
import 'dart:math';

import 'package:logging/logging.dart';

import '../utils/format.dart';

final _log = Logger('sleep_timer');

/// Runs out after a set time, fading the volume out over its last
/// [fadeDuration] before it does, see docs/PLAYBACK.md#sleep-timer.
///
/// The volume goes through [setVolume] (the player's volume, on top of the
/// ReplayGain gains). When the timer runs out, the volume is set to 0, then
/// [onExpired] is called (which pauses), then the volume is set back to 1 for
/// the next play: the player handles its calls in order, so the pause is
/// never heard at full volume.
class SleepTimer {
  /// How long the volume fades out before the timer runs out
  static const fadeDuration = Duration(seconds: 30);

  /// How often the volume changes during the fade
  static const _fadeStep = Duration(milliseconds: 250);

  final void Function(double volume) _setVolume;
  final void Function() _onExpired;
  final DateTime Function() _clock;

  Timer? _timer;
  // Until the fade starts, then for each of its steps
  Timer? _fadeTimer;
  // How long the current timer's fade lasts: fadeDuration, or the whole
  // timer if it's shorter
  Duration _fadeLength = fadeDuration;
  Duration? _duration;
  DateTime? _startTime;

  SleepTimer({
    required void Function(double volume) setVolume,
    required void Function() onExpired,
    DateTime Function() clock = DateTime.now,
  })  : _setVolume = setVolume,
        _onExpired = onExpired,
        _clock = clock;

  bool get isActive => _startTime != null;

  /// The whole time the timer runs, extensions included
  Duration? get duration => _duration;

  /// The time left, taken from the clock
  Duration? get remaining {
    final start = _startTime;
    final duration = _duration;
    if (start == null || duration == null) return null;
    final remaining = duration - _clock().difference(start);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Starts the timer, replacing one that's running.
  void start(Duration duration) {
    _duration = duration;
    _startTime = _clock();
    _log.info('Sleep timer started for ${formatClock(duration)}');
    _schedule(duration);
  }

  /// Stops the timer, at full volume.
  void cancel() {
    _clear();
    _stopFade();
    _log.info('Sleep timer canceled');
  }

  /// Adds [extension] to a running timer. Returns false if none is running.
  bool extend(Duration extension) {
    final left = remaining;
    if (left == null) return false;
    _duration = _duration! + extension;
    final newRemaining = left + extension;
    _log.info('Sleep timer extended by ${formatClock(extension)}, '
        'new remaining: ${formatClock(newRemaining)}');
    _schedule(newRemaining);
    return true;
  }

  /// Stops the timer without touching the volume.
  void dispose() {
    _timer?.cancel();
    _fadeTimer?.cancel();
  }

  /// (Re)schedules the end in [remaining], and the fade out before it. A
  /// fade in progress is undone: the volume is back to full.
  void _schedule(Duration remaining) {
    _timer?.cancel();
    _stopFade();
    _timer = Timer(remaining, _expire);
    // A timer shorter than the fade fades over all of it
    _fadeLength = remaining < fadeDuration ? remaining : fadeDuration;
    _fadeTimer = Timer(remaining - _fadeLength, _startFade);
  }

  void _startFade() {
    _log.info('Sleep timer fading out');
    _fadeTimer = Timer.periodic(_fadeStep, (_) => _applyFade());
    _applyFade();
  }

  /// Sets the volume for the time left. Taken from the clock, not counted in
  /// steps, so the fade ends with the timer even if steps run late. Cubic,
  /// for a fade that sounds even: loudness follows the level in dB, which a
  /// linear ramp would keep high until the last few seconds.
  void _applyFade() {
    final left = remaining;
    if (left == null || _fadeLength <= Duration.zero) return;
    final fraction =
        (left.inMicroseconds / _fadeLength.inMicroseconds).clamp(0.0, 1.0);
    _setVolume(pow(fraction, 3).toDouble());
  }

  /// Stops the fade, back at full volume if it had started.
  void _stopFade() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _setVolume(1.0);
  }

  void _expire() {
    _log.info('Sleep timer expired - pausing playback');
    _fadeTimer?.cancel();
    _fadeTimer = null;
    // Silent until paused, then back to full volume for the next play
    _setVolume(0.0);
    // Inactive by the time [_onExpired] runs
    _clear();
    _onExpired();
    _setVolume(1.0);
  }

  void _clear() {
    _timer?.cancel();
    _timer = null;
    _duration = null;
    _startTime = null;
  }
}
