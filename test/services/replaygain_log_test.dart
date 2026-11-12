import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:voidweaver/services/replaygain/replaygain_log.dart';

void main() {
  final logger = Logger('replaygain');

  setUp(() => hierarchicalLoggingEnabled = true);
  tearDown(() => logger.level = null);

  test('builds no line while FINE isn\'t logged', () {
    logger.level = Level.INFO;
    expect(replayGainLogging, isFalse);

    logReplayGain(() => fail('the line was built'));
  });

  test('logs the line at FINE, which the session log keeps', () async {
    logger.level = Level.FINE;
    final records = <LogRecord>[];
    final subscription = logger.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    expect(replayGainLogging, isTrue);

    logReplayGain(() => '[ReplayGain] TrackGain: -6.00 dB');

    expect(records.single.level, Level.FINE);
    expect(records.single.message, '[ReplayGain] TrackGain: -6.00 dB');
  });
}
