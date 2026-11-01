import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

final _log = Logger('error_handler');

/// Global error handler service that catches and manages uncaught exceptions
/// throughout the application.
class ErrorHandler {
  static ErrorHandler? _instance;
  static ErrorHandler get instance => _instance ??= ErrorHandler._();

  ErrorHandler._();

  final List<ErrorReporter> _reporters = [];
  late final FlutterErrorDetails Function(Object error, StackTrace? stackTrace)
      _errorDetailsBuilder;

  /// Initialize the global error handler.
  /// This should be called early in main() before runApp().
  void initialize() {
    // Handle Flutter framework errors
    FlutterError.onError = (FlutterErrorDetails details) {
      _handleFlutterError(details);
    };

    // Handle errors outside of Flutter framework (like in Isolates)
    PlatformDispatcher.instance.onError = (error, stack) {
      _handlePlatformError(error, stack);
      return true; // Indicate that we've handled the error
    };

    // Handle errors in async operations that don't bubble up to Flutter
    runZonedGuarded(() {
      // This zone captures any unhandled async errors
    }, (error, stack) {
      _handleAsyncError(error, stack);
    });

    _errorDetailsBuilder = (Object error, StackTrace? stackTrace) {
      return FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'error_handler',
        context: ErrorDescription('Global error handler'),
        informationCollector: () => [
          DiagnosticsProperty('timestamp', DateTime.now().toIso8601String()),
          DiagnosticsProperty('platform', defaultTargetPlatform.name),
        ],
      );
    };

    _log.fine('ErrorHandler initialized');
  }

  /// Add an error reporter to receive error notifications
  void addReporter(ErrorReporter reporter) {
    _reporters.add(reporter);
  }

  void _handleFlutterError(FlutterErrorDetails details) {
    // Always log to console in debug mode
    if (kDebugMode) {
      FlutterError.presentError(details);
    }

    // Report to all registered reporters
    for (final reporter in _reporters) {
      try {
        reporter.reportError(details);
      } catch (e) {
        // Don't let reporter errors crash the app
        _log.warning('Error reporter failed', e);
      }
    }
  }

  void _handlePlatformError(Object error, StackTrace stack) {
    final details = _errorDetailsBuilder(error, stack);
    _handleFlutterError(details);
  }

  void _handleAsyncError(Object error, StackTrace stack) {
    final details = _errorDetailsBuilder(error, stack);
    _handleFlutterError(details);
  }

  /// Manually report an error that was caught and handled
  void reportError(Object error, StackTrace? stackTrace, {String? context}) {
    final details = FlutterErrorDetails(
      exception: error,
      stack: stackTrace,
      library: 'error_handler',
      context: ErrorDescription(context ?? 'Manually reported error'),
    );
    _handleFlutterError(details);
  }

  /// Run a function with error handling
  T runWithErrorHandling<T>(T Function() function, {String? context}) {
    try {
      return function();
    } catch (error, stackTrace) {
      reportError(error, stackTrace, context: context);
      rethrow;
    }
  }

  /// Run an async function with error handling
  Future<T> runAsyncWithErrorHandling<T>(
    Future<T> Function() function, {
    String? context,
  }) async {
    try {
      return await function();
    } catch (error, stackTrace) {
      reportError(error, stackTrace, context: context);
      rethrow;
    }
  }
}

/// Abstract interface for error reporting implementations
abstract class ErrorReporter {
  void reportError(FlutterErrorDetails details);
}

/// Logs errors at `SEVERE`, so they reach the console (logcat) in release
/// builds too, see setUpLogging()
class ConsoleErrorReporter implements ErrorReporter {
  @override
  void reportError(FlutterErrorDetails details) {
    _log.severe(details.context?.toString() ?? 'Uncaught error',
        details.exception, details.stack);
  }
}
