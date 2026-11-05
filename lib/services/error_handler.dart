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

  /// Initialize the global error handler.
  /// This should be called early in main() before runApp(). Errors in async
  /// code outside the framework reach [reportError] through the zone that
  /// main() runs the app in.
  void initialize() {
    // Handle Flutter framework errors
    FlutterError.onError = _handleFlutterError;

    // Handle errors that reach the root isolate's dispatcher
    PlatformDispatcher.instance.onError = (error, stack) {
      _handleFlutterError(_errorDetails(error, stack, 'Platform error'));
      return true; // Indicate that we've handled the error
    };

    _log.fine('ErrorHandler initialized');
  }

  /// Add an error reporter to receive error notifications
  void addReporter(ErrorReporter reporter) {
    _reporters.add(reporter);
  }

  /// Remove a reporter added with [addReporter]
  void removeReporter(ErrorReporter reporter) {
    _reporters.remove(reporter);
  }

  FlutterErrorDetails _errorDetails(
    Object error,
    StackTrace? stackTrace,
    String context,
  ) {
    return FlutterErrorDetails(
      exception: error,
      stack: stackTrace,
      library: 'error_handler',
      context: ErrorDescription(context),
      informationCollector: () => [
        DiagnosticsProperty('timestamp', DateTime.now().toIso8601String()),
        DiagnosticsProperty('platform', defaultTargetPlatform.name),
      ],
    );
  }

  void _handleFlutterError(FlutterErrorDetails details) {
    // Always log to console in debug mode
    if (kDebugMode) {
      FlutterError.presentError(details);
    }

    // Report to all registered reporters; a copy, so a reporter may remove
    // itself
    for (final reporter in List.of(_reporters)) {
      try {
        reporter.reportError(details);
      } catch (e) {
        // Don't let reporter errors crash the app
        _log.warning('Error reporter failed', e);
      }
    }
  }

  /// Manually report an error that was caught and handled
  void reportError(Object error, StackTrace? stackTrace, {String? context}) {
    _handleFlutterError(
      _errorDetails(error, stackTrace, context ?? 'Manually reported error'),
    );
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
    _log.severe(
      details.context?.toString() ?? 'Uncaught error',
      details.exception,
      details.stack,
    );
  }
}
