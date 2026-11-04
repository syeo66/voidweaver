import '../replaygain_debug_logger.dart';

// Set in the background isolate of `ReplayGainReader`'s parse, which has
// neither the main isolate's log levels nor its debug log: there the lines
// are collected (if logging is on), and logged on the main isolate
// afterwards. The parse is synchronous, so nothing else runs in that isolate
// meanwhile.
bool _collecting = false;
List<String>? _collectedLines;

/// Logs a line while reading ReplayGain tags to the console and the
/// ReplayGain debug log, see [logReplayGain]. [message] is only built if one
/// of them takes it. Inside [collectReaderLog] the lines are collected
/// instead.
void readerLog(String Function() message) {
  if (_collecting) {
    _collectedLines?.add(message());
  } else {
    logReplayGain(message);
  }
}

/// Runs [body] in a background isolate, collecting the lines [readerLog]
/// gets meanwhile if [logging] is on (the main isolate's
/// [replayGainLogging]), to be logged on the main isolate afterwards.
(T, List<String>?) collectReaderLog<T>(bool logging, T Function() body) {
  _collecting = true;
  _collectedLines = logging ? <String>[] : null;
  return (body(), _collectedLines);
}
