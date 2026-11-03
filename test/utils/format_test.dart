import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/utils/format.dart';

void main() {
  group('formatClock', () {
    test('pads seconds, not minutes', () {
      expect(formatClock(Duration.zero), '0:00');
      expect(formatClock(const Duration(seconds: 65)), '1:05');
      expect(formatClock(const Duration(minutes: 3, seconds: 59)), '3:59');
    });

    test('counts minutes past an hour', () {
      expect(formatClock(const Duration(hours: 1, minutes: 15)), '75:00');
    });

    test('drops fractions of a second', () {
      expect(formatClock(const Duration(milliseconds: 1999)), '0:01');
    });
  });

  group('formatHoursMinutes', () {
    test('minutes only below an hour', () {
      expect(formatHoursMinutes(Duration.zero), '0m');
      expect(formatHoursMinutes(const Duration(minutes: 45)), '45m');
    });

    test('hours and minutes from an hour', () {
      expect(formatHoursMinutes(const Duration(hours: 1)), '1h 0m');
      expect(formatHoursMinutes(const Duration(hours: 2, minutes: 5)), '2h 5m');
    });
  });

  group('formatBytes', () {
    test('picks the unit by size', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1023), '1023 B');
      expect(formatBytes(1024), '1 KB');
      expect(formatBytes(12 * 1024 + 300), '12 KB');
      expect(formatBytes((3.4 * 1024 * 1024).round()), '3.4 MB');
      expect(formatBytes((1.25 * 1024 * 1024 * 1024).round()), '1.25 GB');
    });
  });
}
