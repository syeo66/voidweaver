import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Global error handler service that catches and manages uncaught exceptions
/// throughout the application.
class ErrorHandler {
  static ErrorHandler? _instance;
  static ErrorHandler get instance => _instance ??= ErrorHandler._();

  ErrorHandler._();

  final List<ErrorReporter> _reporters = [];
  late final FlutterErrorDetails Function(dynamic error, StackTrace? stackTrace)
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

    _errorDetailsBuilder = (dynamic error, StackTrace? stackTrace) {
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

    if (kDebugMode) {
      print('ErrorHandler initialized');
    }
  }

  /// Add an error reporter to receive error notifications
  void addReporter(ErrorReporter reporter) {
    _reporters.add(reporter);
  }

  /// Remove an error reporter
  void removeReporter(ErrorReporter reporter) {
    _reporters.remove(reporter);
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
        if (kDebugMode) {
          print('Error reporter failed: $e');
        }
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

/// Console error reporter for development
class ConsoleErrorReporter implements ErrorReporter {
  @override
  void reportError(FlutterErrorDetails details) {
    if (kDebugMode) {
      print('=== ERROR REPORT ===');
      print('Time: ${DateTime.now()}');
      print('Error: ${details.exception}');
      if (details.stack != null) {
        print('Stack trace:');
        print(details.stack);
      }
      if (details.context != null) {
        print('Context: ${details.context}');
      }
      print('==================');
    }
  }
}

/// In-memory error reporter that stores recent errors for debugging
class MemoryErrorReporter implements ErrorReporter {
  final List<ErrorRecord> _errors = [];
  final int maxErrors;

  MemoryErrorReporter({this.maxErrors = 50});

  @override
  void reportError(FlutterErrorDetails details) {
    final record = ErrorRecord(
      timestamp: DateTime.now(),
      error: details.exception.toString(),
      stackTrace: details.stack?.toString(),
      context: details.context?.toString(),
    );

    _errors.add(record);

    // Keep only the most recent errors
    if (_errors.length > maxErrors) {
      _errors.removeAt(0);
    }
  }

  List<ErrorRecord> get errors => List.unmodifiable(_errors);

  void clearErrors() {
    _errors.clear();
  }
}

/// Represents a recorded error for debugging purposes
class ErrorRecord {
  final DateTime timestamp;
  final String error;
  final String? stackTrace;
  final String? context;

  const ErrorRecord({
    required this.timestamp,
    required this.error,
    this.stackTrace,
    this.context,
  });

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.writeln('Error at ${timestamp.toIso8601String()}:');
    buffer.writeln(error);
    if (context != null) {
      buffer.writeln('Context: $context');
    }
    if (stackTrace != null) {
      buffer.writeln('Stack trace:');
      buffer.writeln(stackTrace);
    }
    return buffer.toString();
  }
}

/// Widget to display recent errors for debugging
class ErrorLogViewer extends StatelessWidget {
  final MemoryErrorReporter reporter;

  const ErrorLogViewer({
    super.key,
    required this.reporter,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Error Log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () {
              reporter.clearErrors();
              Navigator.of(context).pop();
            },
            tooltip: 'Clear all errors',
          ),
        ],
      ),
      body: reporter.errors.isEmpty
          ? const Center(
              child: Text('No errors recorded'),
            )
          : ListView.builder(
              itemCount: reporter.errors.length,
              itemBuilder: (context, index) {
                final error =
                    reporter.errors[reporter.errors.length - 1 - index];
                return ExpansionTile(
                  title: Text(
                    error.error,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    error.timestamp.toString(),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (error.context != null) ...[
                            Text(
                              'Context: ${error.context}',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 8),
                          ],
                          if (error.stackTrace != null) ...[
                            Text(
                              'Stack Trace:',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(8.0),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surface,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                error.stackTrace!,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      fontFamily: 'monospace',
                                    ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}
