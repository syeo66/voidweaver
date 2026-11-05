import 'settings_service.dart';

/// How long the current play of a song has actually been heard, and whether
/// it has been scrobbled, see docs/PLAYBACK.md#scrobbling.
///
/// What counts is the time listened, not the position: seeked-over parts
/// don't count. Otherwise seeking to the end of a track and skipping would
/// scrobble it, and subsoxy would take a skip for a play.
class ListeningTracker {
  /// How far the position may move beyond the time that passed between two
  /// position updates and still count as listening, see [onPosition]
  static const _seekTolerance = Duration(seconds: 1);

  final SettingsService _settings;
  final DateTime Function() _clock;

  // When the play started; null for a song restored from a previous session
  // (or paused while it loaded) that hasn't been played yet
  DateTime? _startedAt;
  bool _scrobbled = false;
  Duration _listened = Duration.zero;
  // The last position the player reported, and when
  Duration _lastPosition = Duration.zero;
  DateTime? _lastPositionTime;

  ListeningTracker(this._settings, {this._clock = DateTime.now});

  /// Whether the play has started (and has a start time to scrobble with)
  bool get hasStarted => _startedAt != null;

  /// The time heard so far
  Duration get listened => _listened;

  /// A new play of a song of [songDuration], from [position]. It starts now
  /// if [playing], otherwise on [markStarted]. A song resumed from an earlier
  /// session counts as heard up to [position], and as scrobbled if that's
  /// past the threshold: that happened in the earlier session.
  void startPlay(
    Duration position,
    Duration songDuration, {
    required bool playing,
  }) {
    _startedAt = playing ? _clock() : null;
    _scrobbled =
        position > Duration.zero && reachedThreshold(position, songDuration);
    _listened = position;
    _lastPosition = position;
    _lastPositionTime = _clock();
  }

  /// The play starts now.
  void markStarted() => _startedAt = _clock();

  /// The play hasn't started after all (paused while it loaded).
  void clearStart() => _startedAt = null;

  /// A position update from the player. Adds the time since the last one if
  /// [playing], and only if the position moved by about the time that
  /// passed: a bigger jump is a seek, which isn't listening.
  void onPosition(Duration position, {required bool playing}) {
    final now = _clock();
    final last = _lastPositionTime;
    final advanced = position - _lastPosition;
    if (playing &&
        last != null &&
        advanced > Duration.zero &&
        advanced <= now.difference(last) + _seekTolerance) {
      _listened += advanced;
    }
    _lastPosition = position;
    _lastPositionTime = now;
  }

  /// The song played to its end at [songDuration]: counts the rest after the
  /// last position update as heard.
  void listenedToEnd(Duration songDuration) {
    if (songDuration > _lastPosition) {
      _listened += songDuration - _lastPosition;
    }
    _lastPosition = songDuration;
  }

  /// The play's start time if it should be scrobbled now, which marks it
  /// scrobbled; null if it has been already, hasn't started, or hasn't been
  /// heard long enough. Each play is scrobbled at most once.
  DateTime? takeScrobble(Duration songDuration) {
    final startedAt = _startedAt;
    if (startedAt == null ||
        _scrobbled ||
        !reachedThreshold(_listened, songDuration)) {
      return null;
    }
    _scrobbled = true;
    return startedAt;
  }

  /// Whether [played] of a song of [songDuration] is enough for a scrobble:
  /// the configured minimum play time or percentage, whichever comes first
  /// (see [SettingsService.scrobbleMinPlayTimeMinutes] and
  /// [SettingsService.scrobbleThresholdPercent]).
  bool reachedThreshold(Duration played, Duration songDuration) {
    final minPlayTime = Duration(
      milliseconds: (_settings.scrobbleMinPlayTimeMinutes * 60000).round(),
    );
    if (played >= minPlayTime) return true;

    final fraction = _settings.scrobbleThresholdPercent / 100;
    return songDuration > Duration.zero && played >= songDuration * fraction;
  }
}
