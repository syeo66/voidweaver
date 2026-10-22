import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:voidweaver/utils/log.dart';

void main() {
  group('formatLogRecord', () {
    test('prefixes the level initial and the logger name', () {
      final record = LogRecord(Level.INFO, 'Playing album', 'audio_player');
      expect(formatLogRecord(record), 'I/audio_player: Playing album');
    });

    test('appends the error', () {
      final record = LogRecord(Level.WARNING, 'Search failed', 'subsonic_api',
          const FormatException('bad xml'));
      expect(formatLogRecord(record),
          'W/subsonic_api: Search failed: FormatException: bad xml');
    });

    test('appends the stack trace on its own lines', () {
      final record = LogRecord(Level.SEVERE, 'Uncaught error', 'error_handler',
          'boom', StackTrace.fromString('#0 main'));
      expect(formatLogRecord(record),
          'S/error_handler: Uncaught error: boom\n#0 main');
    });

    test('redacts credentials in the message and the error', () {
      final record = LogRecord(
        Level.WARNING,
        'Request timeout: https://host/rest/ping?u=alice&t=abc&s=xyz',
        'subsonic_api',
        Exception('uri=https://host/rest/getAlbum?id=7&u=alice&p=hunter2'),
      );
      final line = formatLogRecord(record);
      expect(line, isNot(contains('alice')));
      expect(line, isNot(contains('abc')));
      expect(line, isNot(contains('hunter2')));
      expect(line, contains('id=7'));
    });
  });
}
