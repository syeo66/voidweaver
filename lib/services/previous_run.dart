import 'package:logging/logging.dart';
import 'package:voidweaver_player/voidweaver_player.dart';

final _log = Logger('previous_run');

/// Writes how earlier runs of the app ended to the log, see
/// [ProcessHistory]. Android ends a background player for memory, a hang or
/// a crash without the app seeing it, so the previous run's session log just
/// stops; this is the start of the next run's log, and says why. What went
/// wrong is a warning, routine endings are info. Nothing leaves the device.
///
/// Never throws: the log is for finding problems, not a source of them.
Future<void> logPreviousRunEnd({
  ProcessHistory history = const ProcessHistory(),
}) async {
  try {
    for (final event in await history.takeNew()) {
      if (event.notable) {
        _log.warning(event.text);
      } else {
        _log.info(event.text);
      }
    }
  } catch (e) {
    // Not Android, or an older plugin build
    _log.fine('Could not read how the previous run ended', e);
  }
}
