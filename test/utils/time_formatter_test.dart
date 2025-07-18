import 'package:flutter_test/flutter_test.dart';

// Time formatting utility functions (extracted from the codebase)
String formatDuration(Duration duration) {
  if (duration.inHours > 0) {
    return '${duration.inHours}:${(duration.inMinutes % 60).toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
  } else {
    return '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
  }
}

double? parseReplayGainValue(String value) {
  // Extract numeric value including decimal point, scientific notation, and sign
  final match = RegExp(r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?').firstMatch(value);
  if (match == null) return null;
  return double.tryParse(match.group(0)!);
}

bool isValidUrl(String url) {
  try {
    final uri = Uri.parse(url);
    return uri.hasScheme && 
           (uri.scheme == 'http' || uri.scheme == 'https') &&
           uri.host.isNotEmpty;
  } catch (e) {
    return false;
  }
}

String sanitizeFilename(String filename) {
  return filename.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
}

int calculateProgressPercentage(Duration current, Duration total) {
  if (total.inMicroseconds == 0) return 0;
  final percentage = (current.inMicroseconds / total.inMicroseconds * 100).round();
  return percentage.clamp(0, 100);
}

void main() {
  group('Utility Functions Tests', () {
    
    group('Time Formatting', () {
      test('should format duration in minutes and seconds', () {
        expect(formatDuration(const Duration(minutes: 3, seconds: 45)), equals('3:45'));
        expect(formatDuration(const Duration(minutes: 0, seconds: 30)), equals('0:30'));
        expect(formatDuration(const Duration(minutes: 10, seconds: 5)), equals('10:05'));
      });

      test('should format duration with hours', () {
        expect(formatDuration(const Duration(hours: 1, minutes: 30, seconds: 45)), equals('1:30:45'));
        expect(formatDuration(const Duration(hours: 2, minutes: 0, seconds: 0)), equals('2:00:00'));
        expect(formatDuration(const Duration(hours: 1, minutes: 5, seconds: 8)), equals('1:05:08'));
      });

      test('should handle zero duration', () {
        expect(formatDuration(Duration.zero), equals('0:00'));
      });

      test('should handle very long durations', () {
        expect(formatDuration(const Duration(hours: 24, minutes: 59, seconds: 59)), equals('24:59:59'));
        expect(formatDuration(const Duration(hours: 100, minutes: 0, seconds: 0)), equals('100:00:00'));
      });

      test('should pad single digits correctly', () {
        expect(formatDuration(const Duration(minutes: 1, seconds: 5)), equals('1:05'));
        expect(formatDuration(const Duration(hours: 1, minutes: 5, seconds: 5)), equals('1:05:05'));
      });
    });

    group('ReplayGain Value Parsing', () {
      test('should parse valid ReplayGain values', () {
        expect(parseReplayGainValue('-10.5 dB'), equals(-10.5));
        expect(parseReplayGainValue('5.25 dB'), equals(5.25));
        expect(parseReplayGainValue('-3.0'), equals(-3.0));
        expect(parseReplayGainValue('0.0'), equals(0.0));
      });

      test('should handle values without units', () {
        expect(parseReplayGainValue('-10.5'), equals(-10.5));
        expect(parseReplayGainValue('5.25'), equals(5.25));
        expect(parseReplayGainValue('0'), equals(0.0));
      });

      test('should handle malformed values', () {
        expect(parseReplayGainValue('invalid'), isNull);
        expect(parseReplayGainValue(''), isNull);
        expect(parseReplayGainValue('NaN'), isNull);
        expect(parseReplayGainValue('abc-10.5def'), equals(-10.5));
      });

      test('should handle extreme values', () {
        expect(parseReplayGainValue('-999.99 dB'), equals(-999.99));
        expect(parseReplayGainValue('999.99 dB'), equals(999.99));
        expect(parseReplayGainValue('-0.0 dB'), equals(0.0));
      });
    });

    group('URL Validation', () {
      test('should validate correct URLs', () {
        expect(isValidUrl('https://demo.navidrome.org'), isTrue);
        expect(isValidUrl('http://localhost:4533'), isTrue);
        expect(isValidUrl('https://music.example.com:8080'), isTrue);
        expect(isValidUrl('http://192.168.1.100:4533'), isTrue);
      });

      test('should reject invalid URLs', () {
        expect(isValidUrl('invalid-url'), isFalse);
        expect(isValidUrl('ftp://example.com'), isFalse);
        expect(isValidUrl(''), isFalse);
        expect(isValidUrl('not-a-url'), isFalse);
      });

      test('should handle edge cases', () {
        expect(isValidUrl('https://'), isFalse);
        expect(isValidUrl('http://'), isFalse);
        expect(isValidUrl('https://localhost'), isTrue);
        expect(isValidUrl('https://example.com/path?query=value'), isTrue);
      });

      test('should handle special characters in URLs', () {
        expect(isValidUrl('https://example.com/path with spaces'), isTrue);
        expect(isValidUrl('https://user:pass@example.com'), isTrue);
        expect(isValidUrl('https://example.com:8080/path'), isTrue);
      });
    });

    group('Filename Sanitization', () {
      test('should sanitize illegal characters', () {
        expect(sanitizeFilename('Song<Title>'), equals('Song_Title_'));
        expect(sanitizeFilename('Artist: Album'), equals('Artist_ Album'));
        expect(sanitizeFilename('Track/Song'), equals('Track_Song'));
        expect(sanitizeFilename('Song|Title'), equals('Song_Title'));
      });

      test('should handle multiple illegal characters', () {
        expect(sanitizeFilename('Song<>:"/\\|?*Title'), equals('Song_________Title'));
        expect(sanitizeFilename('Artist: "Album" / Track'), equals('Artist_ _Album_ _ Track'));
      });

      test('should preserve legal characters', () {
        expect(sanitizeFilename('Song Title 123'), equals('Song Title 123'));
        expect(sanitizeFilename('Artist - Album (2023)'), equals('Artist - Album (2023)'));
        expect(sanitizeFilename('Track_01.mp3'), equals('Track_01.mp3'));
      });

      test('should handle empty and special cases', () {
        expect(sanitizeFilename(''), equals(''));
        expect(sanitizeFilename('    '), equals('    '));
        expect(sanitizeFilename('....'), equals('....'));
        expect(sanitizeFilename('---'), equals('---'));
      });
    });

    group('Progress Calculation', () {
      test('should calculate progress percentage correctly', () {
        expect(calculateProgressPercentage(
          const Duration(minutes: 1, seconds: 30),
          const Duration(minutes: 3, seconds: 0),
        ), equals(50));

        expect(calculateProgressPercentage(
          const Duration(minutes: 1, seconds: 0),
          const Duration(minutes: 4, seconds: 0),
        ), equals(25));

        expect(calculateProgressPercentage(
          const Duration(minutes: 3, seconds: 0),
          const Duration(minutes: 3, seconds: 0),
        ), equals(100));
      });

      test('should handle edge cases', () {
        expect(calculateProgressPercentage(Duration.zero, Duration.zero), equals(0));
        expect(calculateProgressPercentage(Duration.zero, const Duration(minutes: 3)), equals(0));
        expect(calculateProgressPercentage(const Duration(minutes: 5), const Duration(minutes: 3)), equals(100));
      });

      test('should handle very long durations', () {
        expect(calculateProgressPercentage(
          const Duration(hours: 1, minutes: 30),
          const Duration(hours: 3, minutes: 0),
        ), equals(50));

        expect(calculateProgressPercentage(
          const Duration(milliseconds: 1),
          const Duration(milliseconds: 1000),
        ), equals(0)); // Should round to 0
      });

      test('should clamp values to valid range', () {
        expect(calculateProgressPercentage(
          const Duration(minutes: 5),
          const Duration(minutes: 3),
        ), equals(100)); // Should clamp to 100

        expect(calculateProgressPercentage(
          const Duration(minutes: -1),
          const Duration(minutes: 3),
        ), equals(0)); // Should clamp to 0
      });
    });

    group('Edge Cases and Error Handling', () {
      test('should handle null and empty inputs gracefully', () {
        expect(parseReplayGainValue(''), isNull);
        expect(sanitizeFilename(''), equals(''));
        expect(isValidUrl(''), isFalse);
      });

      test('should handle very large numbers', () {
        expect(parseReplayGainValue('999999.99 dB'), equals(999999.99));
        expect(parseReplayGainValue('-999999.99 dB'), equals(-999999.99));
      });

      test('should handle unicode characters', () {
        expect(sanitizeFilename('Song 🎵 Title'), equals('Song 🎵 Title'));
        expect(sanitizeFilename('Artíst - Albüm'), equals('Artíst - Albüm'));
      });

      test('should handle scientific notation', () {
        expect(parseReplayGainValue('1.5e-2 dB'), equals(0.015));
        expect(parseReplayGainValue('-1.5e2 dB'), equals(-150.0));
      });
    });

    group('Performance and Memory', () {
      test('should handle large strings efficiently', () {
        final largeString = 'A' * 10000;
        expect(sanitizeFilename(largeString), equals(largeString));
      });

      test('should handle many repeated operations', () {
        for (int i = 0; i < 1000; i++) {
          expect(formatDuration(Duration(seconds: i)), isA<String>());
        }
      });

      test('should handle precision in calculations', () {
        expect(calculateProgressPercentage(
          const Duration(microseconds: 1),
          const Duration(microseconds: 3),
        ), equals(33)); // Should handle microsecond precision
      });
    });
  });
}