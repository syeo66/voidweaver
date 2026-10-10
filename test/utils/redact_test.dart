import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/utils/redact.dart';

void main() {
  group('redactCredentials', () {
    test('masks auth params in a URL', () {
      const url =
          'https://music.example.com/rest/ping?u=alice&t=abc123&s=salt&v=1.16.1&c=voidweaver';
      expect(
        redactCredentials(url),
        'https://music.example.com/rest/ping?u=[REDACTED]&t=[REDACTED]'
        '&s=[REDACTED]&v=1.16.1&c=voidweaver',
      );
    });

    test('masks a plaintext password param', () {
      expect(
          redactCredentials('/rest/ping?p=hunter2'), '/rest/ping?p=[REDACTED]');
    });

    test('masks a URL embedded in an exception message', () {
      const message = 'ClientException: Connection refused, '
          'uri=https://host/rest/getAlbum?id=7&u=alice&t=abc&s=xyz';
      final redacted = redactCredentials(message);
      expect(redacted, isNot(contains('alice')));
      expect(redacted, isNot(contains('abc')));
      expect(redacted, isNot(contains('xyz')));
      expect(redacted, contains('id=7'));
    });

    test('leaves params that merely end in u/t/s alone', () {
      const url = 'https://host/rest/search3?query=x&artistCount=5';
      expect(redactCredentials(url), url);
    });
  });
}
