import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Shows a fallback UI in place of [child] when building a widget in it
/// fails, so the rest of the app keeps working.
///
/// Flutter reports a failed build through [FlutterError.onError] (see
/// ErrorHandler) and puts the widget from [ErrorWidget.builder] in place of
/// the failing widget. [install] sets that builder to one that hands the
/// error to the nearest boundary above it. Each boundary only reacts to
/// errors in its own subtree, and [FlutterError.onError] is left alone.
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

  /// Routes build errors to the boundaries. Call once at startup; widgets
  /// outside any boundary still get the previous [ErrorWidget.builder].
  static void install() {
    final outside = ErrorWidget.builder;
    ErrorWidget.builder =
        (details) => _BoundaryErrorWidget(details: details, outside: outside);
  }

  @override
  State<ErrorBoundary> createState() => _ErrorBoundaryState();
}

class _ErrorBoundaryState extends State<ErrorBoundary> {
  FlutterErrorDetails? _error;

  /// A widget in the subtree failed to build. Called after the frame, since
  /// it happens while the subtree builds.
  void _onDescendantError(FlutterErrorDetails details) {
    // The fallback itself failing doesn't replace the first error
    if (!mounted || _error != null) return;
    widget.onError?.call(details);
    setState(() => _error = details);
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
    return widget.child;
  }
}

/// Takes the place of a widget that failed to build (see
/// [ErrorBoundary.install]) and switches the nearest [ErrorBoundary] to its
/// fallback. Empty until then; outside a boundary, shows [outside]'s widget.
class _BoundaryErrorWidget extends StatefulWidget {
  final FlutterErrorDetails details;
  final ErrorWidgetBuilder outside;

  const _BoundaryErrorWidget({required this.details, required this.outside});

  @override
  State<_BoundaryErrorWidget> createState() => _BoundaryErrorWidgetState();
}

class _BoundaryErrorWidgetState extends State<_BoundaryErrorWidget> {
  _ErrorBoundaryState? _boundary;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _boundary = context.findAncestorStateOfType<_ErrorBoundaryState>();
    final boundary = _boundary;
    if (boundary != null) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => boundary._onDescendantError(widget.details));
    }
  }

  @override
  Widget build(BuildContext context) => _boundary == null
      ? widget.outside(widget.details)
      : const SizedBox.shrink();
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
}
