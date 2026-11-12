import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../services/session_log.dart';
import 'redact.dart';

/// Lowest level printed for all loggers. Debug builds print everything,
/// release builds `INFO` and up. Override with e.g.
/// `--dart-define=LOG_LEVEL=FINE` (a [Level] name).
const _logLevelName = String.fromEnvironment('LOG_LEVEL');

/// Comma-separated logger names printed down to `FINE` regardless of
/// [_logLevelName], e.g. `--dart-define=LOG_FINE=audio_player,network`.
const _fineLoggerNames = String.fromEnvironment('LOG_FINE');

StreamSubscription<LogRecord>? _subscription;

/// Prints the records of all loggers to the console (logcat on Android),
/// and hands them to the [SessionLog], which keeps `FINE` and up whatever
/// the console prints. Call once at startup; without it (as in tests)
/// nothing is printed or recorded.
///
/// Each file logs through its own `Logger('<name>')` at one of these levels:
/// - `severe`: unexpected errors, e.g. uncaught ones from [ErrorHandler]
/// - `warning`: failures the app recovers from
/// - `info`: notable events (playback started, scrobble sent)
/// - `fine`: details for debugging (cache hits, retries, state changes)
///
/// Every message and error is passed through [redactCredentials], so URLs
/// with auth parameters can be logged as they are.
void setUpLogging() {
  hierarchicalLoggingEnabled = true;
  final console =
      _levelNamed(_logLevelName) ?? (kDebugMode ? Level.ALL : Level.INFO);
  final fineLoggers = {
    for (final name in _fineLoggerNames.split(','))
      if (name.trim().isNotEmpty) name.trim(),
  };
  // Records are made down to whichever is lower, the console's level or the
  // session log's
  Logger.root.level = console < SessionLog.level ? console : SessionLog.level;
  for (final name in fineLoggers) {
    Logger(name).level = Level.FINE;
  }

  unawaited(_subscription?.cancel());
  _subscription = Logger.root.onRecord.listen((record) {
    if (shouldPrint(record, console, fineLoggers)) {
      debugPrint(formatLogRecord(record));
    }
    SessionLog.instance.add(record);
  });
}

/// Whether the console prints [record]: from the [console] level up, and
/// from `FINE` up for the loggers named in `LOG_FINE` ([fineLoggers]).
@visibleForTesting
bool shouldPrint(LogRecord record, Level console, Set<String> fineLoggers) =>
    record.level >= console ||
    (fineLoggers.contains(record.loggerName) && record.level >= Level.FINE);

/// One line per record (plus the stack trace, if any), e.g.
/// `W/api_cache: Error reading persistent cache: <error>`. Also the
/// [SessionLog]'s lines.
String formatLogRecord(LogRecord record) {
  final buffer = StringBuffer()
    ..write(record.level.name[0])
    ..write('/')
    ..write(record.loggerName)
    ..write(': ')
    ..write(record.message);
  if (record.error != null) buffer.write(': ${record.error}');
  if (record.stackTrace != null) buffer.write('\n${record.stackTrace}');
  return redactCredentials(buffer.toString());
}

Level? _levelNamed(String name) {
  final upper = name.trim().toUpperCase();
  for (final level in Level.LEVELS) {
    if (level.name == upper) return level;
  }
  return null;
}
