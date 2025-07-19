import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/services/error_handler.dart';

void main() {
  group('ErrorHandler Tests', () {
    test('should be a singleton', () {
      final instance1 = ErrorHandler.instance;
      final instance2 = ErrorHandler.instance;
      expect(instance1, same(instance2));
    });

    test('should test error handler components', () {
      // Test that basic components can be instantiated
      final errorHandler = ErrorHandler.instance;
      expect(errorHandler, isNotNull);

      final reporter = TestErrorReporter();
      expect(reporter.errors, isEmpty);

      final consoleReporter = ConsoleErrorReporter();
      expect(consoleReporter, isNotNull);
    });
  });

  group('ConsoleErrorReporter Tests', () {
    test('should not throw when reporting errors', () {
      final reporter = ConsoleErrorReporter();
      final errorDetails = FlutterErrorDetails(
        exception: Exception('Test console error'),
        library: 'test',
      );

      expect(() {
        reporter.reportError(errorDetails);
      }, returnsNormally);
    });
  });

  group('MemoryErrorReporter Tests', () {
    late MemoryErrorReporter reporter;

    setUp(() {
      reporter = MemoryErrorReporter(maxErrors: 3);
    });

    test('should store error records', () {
      final errorDetails = FlutterErrorDetails(
        exception: Exception('Test memory error'),
        library: 'test',
        context: ErrorDescription('Test context'),
      );

      reporter.reportError(errorDetails);

      expect(reporter.errors.length, 1);
      expect(reporter.errors.first.error, contains('Test memory error'));
      expect(reporter.errors.first.context, contains('Test context'));
    });

    test('should limit number of stored errors', () {
      for (int i = 0; i < 5; i++) {
        final errorDetails = FlutterErrorDetails(
          exception: Exception('Error $i'),
          library: 'test',
        );
        reporter.reportError(errorDetails);
      }

      expect(reporter.errors.length, 3);
      expect(reporter.errors.first.error, contains('Error 2'));
      expect(reporter.errors.last.error, contains('Error 4'));
    });

    test('should clear all errors', () {
      final errorDetails = FlutterErrorDetails(
        exception: Exception('Test error'),
        library: 'test',
      );

      reporter.reportError(errorDetails);
      expect(reporter.errors.length, 1);

      reporter.clearErrors();
      expect(reporter.errors.length, 0);
    });
  });

  group('ErrorRecord Tests', () {
    test('should create error record with all fields', () {
      final timestamp = DateTime.now();
      final record = ErrorRecord(
        timestamp: timestamp,
        error: 'Test error',
        stackTrace: 'Stack trace line 1\nStack trace line 2',
        context: 'Test context',
      );

      expect(record.timestamp, timestamp);
      expect(record.error, 'Test error');
      expect(record.stackTrace, contains('Stack trace line 1'));
      expect(record.context, 'Test context');
    });

    test('should handle null optional fields', () {
      final timestamp = DateTime.now();
      final record = ErrorRecord(
        timestamp: timestamp,
        error: 'Test error',
      );

      expect(record.timestamp, timestamp);
      expect(record.error, 'Test error');
      expect(record.stackTrace, isNull);
      expect(record.context, isNull);
    });

    test('toString should format error information properly', () {
      final timestamp = DateTime.now();
      final record = ErrorRecord(
        timestamp: timestamp,
        error: 'Test error message',
        stackTrace: 'Stack trace info',
        context: 'Test context info',
      );

      final stringRepresentation = record.toString();

      expect(stringRepresentation, contains('Test error message'));
      expect(stringRepresentation, contains('Stack trace info'));
      expect(stringRepresentation, contains('Test context info'));
      expect(stringRepresentation, contains(timestamp.toIso8601String()));
    });
  });
}

class TestErrorReporter implements ErrorReporter {
  final List<FlutterErrorDetails> errors = [];

  @override
  void reportError(FlutterErrorDetails details) {
    errors.add(details);
  }

  void clear() {
    errors.clear();
  }
}

class FailingErrorReporter implements ErrorReporter {
  @override
  void reportError(FlutterErrorDetails details) {
    throw Exception('Reporter failure');
  }
}
