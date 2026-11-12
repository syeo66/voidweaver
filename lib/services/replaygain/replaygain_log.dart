import 'package:logging/logging.dart';

import '../../models/subsonic_models.dart';
import '../settings_service.dart';

final _log = Logger('replaygain');

/// Whether ReplayGain diagnostics are logged: the `replaygain` logger
/// makes `FINE` records, which the session log keeps (see setUpLogging()).
/// Off where logging isn't set up (tests), so the lines aren't even built
/// then.
bool get replayGainLogging => _log.isLoggable(Level.FINE);

/// Logs a ReplayGain diagnostic line at `FINE`: to the session log, and to
/// the console in debug builds. [message] is only called if
/// [replayGainLogging] is on: ReplayGain is read for every song played or
/// prefetched.
void logReplayGain(String Function() message) {
  if (!replayGainLogging) return;
  _log.fine(message());
}

/// The lines the session log shows for the track that starts
/// playing: its ReplayGain data, the settings, and the linear [gain] it plays
/// at. [queue] is what the queue was started from (album gains are used in
/// smart mode only for albums).
List<String> trackGainReport(
  Song song,
  SettingsService settings, {
  required double gain,
  required String queue,
}) {
  String db(double? value) => '${value?.toStringAsFixed(2) ?? 'null'} dB';
  String peak(double? value) => value?.toStringAsFixed(4) ?? 'null';
  final rule = '='.padRight(80, '=');
  final ignored = [
    if (song.replayGainTrackGain != null &&
        SettingsService.plausibleGain(song.replayGainTrackGain) == null)
      'trackGain',
    if (song.replayGainAlbumGain != null &&
        SettingsService.plausibleGain(song.replayGainAlbumGain) == null)
      'albumGain',
    if (song.replayGainTrackPeak != null &&
        SettingsService.plausiblePeak(song.replayGainTrackPeak) == null)
      'trackPeak',
    if (song.replayGainAlbumPeak != null &&
        SettingsService.plausiblePeak(song.replayGainAlbumPeak) == null)
      'albumPeak',
  ];
  final usable =
      SettingsService.plausibleGain(song.replayGainTrackGain) != null ||
      SettingsService.plausibleGain(song.replayGainAlbumGain) != null;
  return [
    '',
    rule,
    '[ReplayGain] GAIN OF CURRENT TRACK',
    rule,
    '[ReplayGain] Song: "${song.title}" by "${song.artist}" (id=${song.id})',
    '[ReplayGain] Mode: ${settings.replayGainMode.name} (queue: $queue)',
    '[ReplayGain] TrackGain: ${db(song.replayGainTrackGain)}',
    '[ReplayGain] AlbumGain: ${db(song.replayGainAlbumGain)}',
    '[ReplayGain] TrackPeak: ${peak(song.replayGainTrackPeak)}',
    '[ReplayGain] AlbumPeak: ${peak(song.replayGainAlbumPeak)}',
    '[ReplayGain] Preamp: ${settings.replayGainPreamp.toStringAsFixed(1)} dB',
    '[ReplayGain] Fallback: '
        '${settings.replayGainFallbackGain.toStringAsFixed(1)} dB',
    '[ReplayGain] Prevent Clipping: ${settings.replayGainPreventClipping}',
    if (ignored.isNotEmpty)
      '[ReplayGain] Ignored, out of range: ${ignored.join(', ')}',
    '[ReplayGain] Source: ${usable ? 'METADATA' : 'FALLBACK'}',
    '[ReplayGain] Final Gain Multiplier: ${gain.toStringAsFixed(6)} '
        '(${(gain * 100).toStringAsFixed(2)}%)',
    rule,
    '',
  ];
}
