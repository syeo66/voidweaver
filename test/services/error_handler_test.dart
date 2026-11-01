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
