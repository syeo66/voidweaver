import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:voidweaver/services/error_handler.dart';

class _RecordingReporter implements ErrorReporter {
  final List<FlutterErrorDetails> errors = [];

  @override
  void reportError(FlutterErrorDetails details) => errors.add(details);
}

class _FailingReporter implements ErrorReporter {
  int calls = 0;

  @override
  void reportError(FlutterErrorDetails details) {
    calls++;
    throw Exception('Reporter failure');
  }
}

void main() {
  final handler = ErrorHandler.instance;
  late _RecordingReporter reporter;
  late List<ErrorReporter> added;
  late FlutterExceptionHandler? savedOnError;
  late ErrorCallback? savedPlatformOnError;
  late void Function(FlutterErrorDetails) savedPresentError;

  setUp(() {
    // initialize() replaces global handlers; restored in tearDown
    savedOnError = FlutterError.onError;
    savedPlatformOnError = PlatformDispatcher.instance.onError;
    savedPresentError = FlutterError.presentError;
    // Tests print nothing (debug builds present every error)
    FlutterError.presentError = (_) {};

    reporter = _RecordingReporter();
    added = [reporter];
    handler.addReporter(reporter);
  });

  tearDown(() {
    added.forEach(handler.removeReporter);
    FlutterError.onError = savedOnError;
    PlatformDispatcher.instance.onError = savedPlatformOnError;
    FlutterError.presentError = savedPresentError;
  });

  void addReporter(ErrorReporter r) {
    added.add(r);
    handler.addReporter(r);
  }

  test('is a singleton', () {
    expect(ErrorHandler.instance, same(handler));
  });

  test('reportError passes the error, stack and context to the reporters', () {
    final error = StateError('boom');
    final stack = StackTrace.current;

    handler.reportError(error, stack, context: 'Loading albums');

    expect(reporter.errors, hasLength(1));
    final details = reporter.errors.single;
    expect(details.exception, same(error));
    expect(details.stack, same(stack));
    expect(details.library, 'error_handler');
    expect(details.context.toString(), 'Loading albums');
  });

  test('reportError has a default context', () {
    handler.reportError(Exception('x'), null);

    expect(
        reporter.errors.single.context.toString(), 'Manually reported error');
  });

  test('works before initialize()', () {
    expect(
        () => handler.reportError(Exception('early'), null), returnsNormally);
    expect(reporter.errors, hasLength(1));
  });

  test('a failing reporter does not stop the others', () {
    final failing = _FailingReporter();
    final after = _RecordingReporter();
    // Registered before the recording reporters
    added.remove(reporter);
    handler.removeReporter(reporter);
    addReporter(failing);
    addReporter(after);

    expect(() => handler.reportError(Exception('x'), null), returnsNormally);

    expect(failing.calls, 1);
    expect(after.errors, hasLength(1));
  });

  test('removed reporters get nothing', () {
    handler.removeReporter(reporter);

    handler.reportError(Exception('x'), null);

    expect(reporter.errors, isEmpty);
  });

  test('a reporter may remove itself while reporting', () {
    late ErrorReporter selfRemoving;
    var calls = 0;
    selfRemoving = _CallbackReporter((_) {
      calls++;
      handler.removeReporter(selfRemoving);
    });
    addReporter(selfRemoving);

    handler.reportError(Exception('1'), null);
    handler.reportError(Exception('2'), null);

    expect(calls, 1);
    expect(reporter.errors, hasLength(2));
  });

  group('initialize()', () {
    test('reports Flutter framework errors', () {
      handler.initialize();
      final details = FlutterErrorDetails(
        exception: Exception('build failed'),
        library: 'widgets library',
      );

      FlutterError.onError!(details);

      expect(reporter.errors.single, same(details));
    });

    test('reports platform dispatcher errors and marks them handled', () {
      handler.initialize();
      final error = StateError('platform');
      final stack = StackTrace.current;

      final handled = PlatformDispatcher.instance.onError!(error, stack);

      expect(handled, isTrue);
      final details = reporter.errors.single;
      expect(details.exception, same(error));
      expect(details.stack, same(stack));
      expect(details.context.toString(), 'Platform error');
    });

    test('can be called again', () {
      handler.initialize();
      expect(handler.initialize, returnsNormally);

      FlutterError.onError!(FlutterErrorDetails(exception: Exception('x')));
      expect(reporter.errors, hasLength(1));
    });
  });

  group('ConsoleErrorReporter', () {
    test('logs at SEVERE with the context, error and stack', () async {
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(sub.cancel);
      final error = Exception('console');
      final stack = StackTrace.current;

      ConsoleErrorReporter().reportError(FlutterErrorDetails(
        exception: error,
        stack: stack,
        context: ErrorDescription('Playing a song'),
      ));
      await Future<void>.delayed(Duration.zero);

      final record =
          records.singleWhere((r) => r.loggerName == 'error_handler');
      expect(record.level, Level.SEVERE);
      expect(record.message, 'Playing a song');
      expect(record.error, same(error));
      expect(record.stackTrace, same(stack));
    });

    test('logs errors without a context as uncaught', () async {
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(sub.cancel);

      ConsoleErrorReporter()
          .reportError(FlutterErrorDetails(exception: Exception('x')));
      await Future<void>.delayed(Duration.zero);

      expect(
          records.singleWhere((r) => r.loggerName == 'error_handler').message,
          'Uncaught error');
    });
  });
}

class _CallbackReporter implements ErrorReporter {
  final void Function(FlutterErrorDetails) onReport;

  _CallbackReporter(this.onReport);

  @override
  void reportError(FlutterErrorDetails details) => onReport(details);
}
