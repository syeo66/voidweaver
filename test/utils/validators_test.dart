import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/utils/validators.dart';

void main() {
  group('Server URL Validation', () {
    test('should accept valid HTTP URLs', () {
      expect(Validators.validateServerUrl('http://example.com'), isNull);
      expect(Validators.validateServerUrl('http://music.example.com'), isNull);
      expect(Validators.validateServerUrl('http://192.168.1.100:8080'), isNull);
      expect(Validators.validateServerUrl('http://localhost:4040'), isNull);
    });

    test('should accept valid HTTPS URLs', () {
      expect(Validators.validateServerUrl('https://example.com'), isNull);
      expect(Validators.validateServerUrl('https://music.example.com'), isNull);
      expect(Validators.validateServerUrl('https://subsonic.mydomain.org'), isNull);
      expect(Validators.validateServerUrl('https://server.com:8443'), isNull);
    });

    test('should reject empty or null URLs', () {
      expect(Validators.validateServerUrl(null), 'Server URL is required');
      expect(Validators.validateServerUrl(''), 'Server URL is required');
      expect(Validators.validateServerUrl('   '), 'Server URL is required');
    });

    test('should reject invalid URLs', () {
      expect(Validators.validateServerUrl('not-a-url'), contains('Please enter a valid URL'));
      expect(Validators.validateServerUrl('example.com'), contains('Please enter a valid URL'));
      expect(Validators.validateServerUrl('://missing-scheme'), contains('Please enter a valid URL'));
    });

    test('should reject unsupported protocols', () {
      expect(Validators.validateServerUrl('ftp://example.com'), contains('URL must use http or https protocol'));
      expect(Validators.validateServerUrl('ws://example.com'), contains('URL must use http or https protocol'));
      expect(Validators.validateServerUrl('file:///path'), contains('URL must use http or https protocol'));
    });

    test('should reject URLs without hostname', () {
      expect(Validators.validateServerUrl('http://'), contains('URL must include a hostname'));
      expect(Validators.validateServerUrl('https://'), contains('URL must include a hostname'));
    });


    test('should reject extremely long URLs', () {
      final longUrl = 'https://${'a' * 2050}.com';
      expect(Validators.validateServerUrl(longUrl), contains('Server URL is too long'));
    });

    test('should handle URLs with paths and parameters', () {
      expect(Validators.validateServerUrl('https://example.com/subsonic'), isNull);
      expect(Validators.validateServerUrl('https://example.com/path?param=value'), isNull);
      expect(Validators.validateServerUrl('https://example.com:8080/subsonic/rest'), isNull);
    });
  });

  group('Username Validation', () {
    test('should accept valid usernames', () {
      expect(Validators.validateUsername('john'), isNull);
      expect(Validators.validateUsername('user123'), isNull);
      expect(Validators.validateUsername('test_user'), isNull);
      expect(Validators.validateUsername('admin@example.com'), isNull);
      expect(Validators.validateUsername('user-name'), isNull);
    });

    test('should reject empty or null usernames', () {
      expect(Validators.validateUsername(null), 'Username is required');
      expect(Validators.validateUsername(''), 'Username is required');
      expect(Validators.validateUsername('   '), 'Username is required');
    });

    test('should reject usernames with invalid characters', () {
      expect(Validators.validateUsername('user\nname'), contains('Username contains invalid characters'));
      expect(Validators.validateUsername('user\rname'), contains('Username contains invalid characters'));
      expect(Validators.validateUsername('user\tname'), contains('Username contains invalid characters'));
    });

    test('should reject excessively long usernames', () {
      final longUsername = 'a' * 101;
      expect(Validators.validateUsername(longUsername), contains('Username is too long'));
    });

    test('should trim whitespace', () {
      expect(Validators.validateUsername('  valid  '), isNull);
    });
  });

  group('Password Validation', () {
    test('should accept valid passwords', () {
      expect(Validators.validatePassword('password'), isNull);
      expect(Validators.validatePassword('P@ssw0rd!'), isNull);
      expect(Validators.validatePassword('123456'), isNull);
      expect(Validators.validatePassword('very-long-password-with-special-chars!@#'), isNull);
    });

    test('should reject empty or null passwords', () {
      expect(Validators.validatePassword(null), 'Password is required');
      expect(Validators.validatePassword(''), 'Password is required');
    });

    test('should reject passwords with invalid characters', () {
      expect(Validators.validatePassword('pass\nword'), contains('Password contains invalid characters'));
      expect(Validators.validatePassword('pass\rword'), contains('Password contains invalid characters'));
      expect(Validators.validatePassword('pass\tword'), contains('Password contains invalid characters'));
    });

    test('should reject excessively long passwords', () {
      final longPassword = 'a' * 257;
      expect(Validators.validatePassword(longPassword), contains('Password is too long'));
    });

    test('should allow passwords up to 256 characters', () {
      final maxPassword = 'a' * 256;
      expect(Validators.validatePassword(maxPassword), isNull);
    });
  });

  group('ReplayGain Preamp Validation', () {
    test('should accept valid preamp values', () {
      expect(Validators.validateReplayGainPreamp(0.0), isNull);
      expect(Validators.validateReplayGainPreamp(-15.0), isNull);
      expect(Validators.validateReplayGainPreamp(15.0), isNull);
      expect(Validators.validateReplayGainPreamp(5.5), isNull);
      expect(Validators.validateReplayGainPreamp(-7.2), isNull);
    });

    test('should reject null values', () {
      expect(Validators.validateReplayGainPreamp(null), 'Preamp value is required');
    });

    test('should reject values outside valid range', () {
      expect(Validators.validateReplayGainPreamp(-15.1), contains('Preamp cannot be less than -15.0 dB'));
      expect(Validators.validateReplayGainPreamp(15.1), contains('Preamp cannot be greater than 15.0 dB'));
      expect(Validators.validateReplayGainPreamp(-100.0), contains('Preamp cannot be less than -15.0 dB'));
      expect(Validators.validateReplayGainPreamp(100.0), contains('Preamp cannot be greater than 15.0 dB'));
    });

    test('should reject invalid numeric values', () {
      expect(Validators.validateReplayGainPreamp(double.nan), 'Invalid preamp value');
      expect(Validators.validateReplayGainPreamp(double.infinity), 'Invalid preamp value');
      expect(Validators.validateReplayGainPreamp(double.negativeInfinity), 'Invalid preamp value');
    });
  });

  group('ReplayGain Fallback Gain Validation', () {
    test('should accept valid fallback gain values', () {
      expect(Validators.validateReplayGainFallbackGain(0.0), isNull);
      expect(Validators.validateReplayGainFallbackGain(-15.0), isNull);
      expect(Validators.validateReplayGainFallbackGain(15.0), isNull);
      expect(Validators.validateReplayGainFallbackGain(3.7), isNull);
      expect(Validators.validateReplayGainFallbackGain(-8.9), isNull);
    });

    test('should reject null values', () {
      expect(Validators.validateReplayGainFallbackGain(null), 'Fallback gain value is required');
    });

    test('should reject values outside valid range', () {
      expect(Validators.validateReplayGainFallbackGain(-15.1), contains('Fallback gain cannot be less than -15.0 dB'));
      expect(Validators.validateReplayGainFallbackGain(15.1), contains('Fallback gain cannot be greater than 15.0 dB'));
    });

    test('should reject invalid numeric values', () {
      expect(Validators.validateReplayGainFallbackGain(double.nan), 'Invalid fallback gain value');
      expect(Validators.validateReplayGainFallbackGain(double.infinity), 'Invalid fallback gain value');
      expect(Validators.validateReplayGainFallbackGain(double.negativeInfinity), 'Invalid fallback gain value');
    });
  });

  group('URL Validation Helper', () {
    test('should correctly identify valid URLs', () {
      expect(Validators.isValidUrl('https://example.com'), isTrue);
      expect(Validators.isValidUrl('http://localhost:8080'), isTrue);
      expect(Validators.isValidUrl('https://music.mydomain.org'), isTrue);
    });

    test('should correctly identify invalid URLs', () {
      expect(Validators.isValidUrl(null), isFalse);
      expect(Validators.isValidUrl(''), isFalse);
      expect(Validators.isValidUrl('not-a-url'), isFalse);
      expect(Validators.isValidUrl('ftp://example.com'), isFalse);
      expect(Validators.isValidUrl('example.com'), isFalse);
    });
  });

  group('Input Sanitization', () {
    test('should remove control characters', () {
      expect(Validators.sanitizeInput('test\x00string'), 'teststring');
      expect(Validators.sanitizeInput('test\x1Fstring'), 'teststring');
      expect(Validators.sanitizeInput('test\x7Fstring'), 'teststring');
    });

    test('should replace newlines and tabs with spaces', () {
      expect(Validators.sanitizeInput('test\nstring'), 'test string');
      expect(Validators.sanitizeInput('test\rstring'), 'test string');
      expect(Validators.sanitizeInput('test\tstring'), 'test string');
      expect(Validators.sanitizeInput('test\n\r\tstring'), 'test   string');
    });

    test('should trim whitespace', () {
      expect(Validators.sanitizeInput('  test string  '), 'test string');
      expect(Validators.sanitizeInput('\n\ttest\r\n'), 'test');
    });

    test('should handle null input', () {
      expect(Validators.sanitizeInput(null), '');
    });

    test('should handle empty input', () {
      expect(Validators.sanitizeInput(''), '');
      expect(Validators.sanitizeInput('   '), '');
    });

    test('should preserve valid characters', () {
      expect(Validators.sanitizeInput('Valid String 123 !@#'), 'Valid String 123 !@#');
      expect(Validators.sanitizeInput('user@example.com'), 'user@example.com');
    });
  });

  group('Generic Validation Helpers', () {
    test('validateNonEmpty should work correctly', () {
      expect(Validators.validateNonEmpty('valid', 'Field'), isNull);
      expect(Validators.validateNonEmpty(null, 'Field'), 'Field is required');
      expect(Validators.validateNonEmpty('', 'Field'), 'Field is required');
      expect(Validators.validateNonEmpty('   ', 'Field'), 'Field is required');
    });

    test('validateLength should work correctly', () {
      expect(Validators.validateLength('short', 10, 'Field'), isNull);
      expect(Validators.validateLength('toolongstring', 5, 'Field'), 'Field is too long (max 5 characters)');
      expect(Validators.validateLength(null, 10, 'Field'), isNull);
    });

    test('validateRange should work correctly', () {
      expect(Validators.validateRange(5.0, 0.0, 10.0, 'Value'), isNull);
      expect(Validators.validateRange(0.0, 0.0, 10.0, 'Value'), isNull);
      expect(Validators.validateRange(10.0, 0.0, 10.0, 'Value'), isNull);
      expect(Validators.validateRange(-1.0, 0.0, 10.0, 'Value'), 'Value cannot be less than 0.0');
      expect(Validators.validateRange(11.0, 0.0, 10.0, 'Value'), 'Value cannot be greater than 10.0');
      expect(Validators.validateRange(null, 0.0, 10.0, 'Value'), 'Value is required');
      expect(Validators.validateRange(double.nan, 0.0, 10.0, 'Value'), 'Invalid Value value');
    });
  });
}