import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A widget that catches errors in its child widgets and displays a fallback UI.
/// This prevents the entire app from crashing when a widget throws an error.
class ErrorBoundary extends StatefulWidget {
  final Widget child;
  final Widget Function(FlutterErrorDetails error)? fallbackBuilder;
  final void Function(FlutterErrorDetails error)? onError;
  final String? errorMessage;

  const ErrorBoundary({
    super.key,
    required this.child,
    this.fallbackBuilder,
    this.onError,
    this.errorMessage,
  });

  @override
  State<ErrorBoundary> createState() => _ErrorBoundaryState();
}

class _ErrorBoundaryState extends State<ErrorBoundary> {
  FlutterErrorDetails? _error;

  @override
  void initState() {
    super.initState();

    // Set up error handling for this widget's context
    FlutterError.onError = (FlutterErrorDetails details) {
      // Log the error
      if (kDebugMode) {
        FlutterError.presentError(details);
      }

      // Call the onError callback if provided
      widget.onError?.call(details);

      // Set the error state to show fallback UI
      if (mounted) {
        setState(() {
          _error = details;
        });
      }
    };
  }

  Widget _buildFallbackUI(FlutterErrorDetails error) {
    if (widget.fallbackBuilder != null) {
      return widget.fallbackBuilder!(error);
    }

    return ErrorDisplay(
      error: error,
      message: widget.errorMessage,
      onRetry: () {
        setState(() {
          _error = null;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _buildFallbackUI(_error!);
    }

    // Wrap child in a Builder to catch build-time errors
    return Builder(
      builder: (context) {
        try {
          return widget.child;
        } catch (error, stackTrace) {
          final details = FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'error_boundary',
            context: ErrorDescription('Error caught by ErrorBoundary'),
          );

          widget.onError?.call(details);

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _error = details;
              });
            }
          });

          return _buildFallbackUI(details);
        }
      },
    );
  }
}

/// A standardized error display widget that shows error information
/// and provides options for the user to recover.
class ErrorDisplay extends StatelessWidget {
  final FlutterErrorDetails error;
  final String? message;
  final VoidCallback? onRetry;
  final VoidCallback? onReport;
  final bool showDetails;

  const ErrorDisplay({
    super.key,
    required this.error,
    this.message,
    this.onRetry,
    this.onReport,
    this.showDetails = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 64,
            color: theme.colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text(
            'Something went wrong',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.error,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            message ?? 'An unexpected error occurred. Please try again.',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          if (showDetails && kDebugMode) ...[
            const SizedBox(height: 16),
            ExpansionTile(
              title: const Text('Error Details'),
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8.0),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    error.toString(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (onRetry != null)
                ElevatedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try Again'),
                ),
              if (onRetry != null && onReport != null)
                const SizedBox(width: 16),
              if (onReport != null)
                TextButton.icon(
                  onPressed: onReport,
                  icon: const Icon(Icons.bug_report),
                  label: const Text('Report Issue'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A specialized error boundary for async operations like network requests.
class AsyncErrorBoundary extends StatefulWidget {
  final Widget child;
  final Future<void> Function()? onRetry;
  final String? errorMessage;

  const AsyncErrorBoundary({
    super.key,
    required this.child,
    this.onRetry,
    this.errorMessage,
  });

  @override
  State<AsyncErrorBoundary> createState() => _AsyncErrorBoundaryState();
}

class _AsyncErrorBoundaryState extends State<AsyncErrorBoundary> {
  bool _hasError = false;
  Object? _error;
  bool _isRetrying = false;

  void _handleError(Object error) {
    if (mounted) {
      setState(() {
        _hasError = true;
        _error = error;
        _isRetrying = false;
      });
    }
  }

  Future<void> _retry() async {
    if (widget.onRetry == null) return;

    setState(() {
      _isRetrying = true;
    });

    try {
      await widget.onRetry!();
      if (mounted) {
        setState(() {
          _hasError = false;
          _error = null;
          _isRetrying = false;
        });
      }
    } catch (error) {
      _handleError(error);
    }
  }

  Widget _buildErrorUI() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 48,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text(
            widget.errorMessage ?? 'Failed to load data',
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          if (kDebugMode && _error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error.toString(),
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 16),
          if (widget.onRetry != null)
            ElevatedButton.icon(
              onPressed: _isRetrying ? null : _retry,
              icon: _isRetrying
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(_isRetrying ? 'Retrying...' : 'Try Again'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return _buildErrorUI();
    }

    return widget.child;
  }
}

/// Extension to easily wrap widgets with error boundaries
extension ErrorBoundaryExtension on Widget {
  Widget withErrorBoundary({
    Widget Function(FlutterErrorDetails error)? fallbackBuilder,
    void Function(FlutterErrorDetails error)? onError,
    String? errorMessage,
  }) {
    return ErrorBoundary(
      fallbackBuilder: fallbackBuilder,
      onError: onError,
      errorMessage: errorMessage,
      child: this,
    );
  }

  Widget withAsyncErrorBoundary({
    Future<void> Function()? onRetry,
    String? errorMessage,
  }) {
    return AsyncErrorBoundary(
      onRetry: onRetry,
      errorMessage: errorMessage,
      child: this,
    );
  }
}
