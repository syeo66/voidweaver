import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/services/subsonic_api.dart';

void main() {
  // Initialize Flutter test binding
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SubsonicApi HTTPS Enforcement', () {
    test('should accept HTTPS URLs', () async {
      // Mock the SharedPreferences plugin for testing
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/shared_preferences'),
              (MethodCall methodCall) async {
        return <String, dynamic>{};
      });

      expect(
        () => SubsonicApi(
          serverUrl: 'https://demo.navidrome.org',
          username: 'testuser',
          password: 'testpass',
        ),
        returnsNormally,
      );
    });

    test('should reject HTTP URLs', () {
      expect(
        () => SubsonicApi(
          serverUrl: 'http://demo.navidrome.org',
          username: 'testuser',
          password: 'testpass',
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('Server URL must use HTTPS protocol for security'),
        )),
      );
    });

    test('should reject invalid URLs', () {
      expect(
        () => SubsonicApi(
          serverUrl: 'not-a-url',
          username: 'testuser',
          password: 'testpass',
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('Server URL must use HTTPS protocol for security'),
        )),
      );
    });

    test('should reject FTP URLs', () {
      expect(
        () => SubsonicApi(
          serverUrl: 'ftp://example.com',
          username: 'testuser',
          password: 'testpass',
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('Server URL must use HTTPS protocol for security'),
        )),
      );
    });

    test('should dispose properly after creation', () async {
      // Mock the SharedPreferences plugin for testing
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/shared_preferences'),
              (MethodCall methodCall) async {
        return <String, dynamic>{};
      });

      final api = SubsonicApi(
        serverUrl: 'https://demo.navidrome.org',
        username: 'testuser',
        password: 'testpass',
      );

      // Should not throw when disposing
      expect(() => api.dispose(), returnsNormally);
    });
  });
}
