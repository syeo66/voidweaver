import 'dart:io';
import 'network_config.dart';

/// Helper class for converting network exceptions to user-friendly messages
class NetworkErrorHelper {
  /// Convert any network-related exception to a user-friendly message
  static String getErrorMessage(Object error, {String? context}) {
    final baseContext = context != null ? '$context: ' : '';

    if (error is NetworkTimeoutException) {
      return _getTimeoutMessage(error, baseContext);
    }

    if (error is NetworkConnectionException) {
      return _getConnectionMessage(error, baseContext);
    }

    if (error is SocketException) {
      return _getSocketExceptionMessage(error, baseContext);
    }

    if (error is HttpException) {
      return _getHttpExceptionMessage(error, baseContext);
    }

    // Handle generic timeout errors
    final errorString = error.toString().toLowerCase();
    if (errorString.contains('timeout') || errorString.contains('timed out')) {
      return '${baseContext}Request timed out. Please check your connection and try again.';
    }

    // Handle connection errors in generic exceptions
    if (errorString.contains('connection') ||
        errorString.contains('network') ||
        errorString.contains('host')) {
      return '${baseContext}Unable to connect to server. Please check your internet connection.';
    }

    // Generic network error
    return '${baseContext}Network error occurred. Please try again.';
  }

  static String _getTimeoutMessage(
      NetworkTimeoutException error, String baseContext) {
    final timeoutSeconds = error.totalDuration.inSeconds;
    final attempts = error.attemptsMade;

    if (timeoutSeconds < 30) {
      return '${baseContext}Connection timed out quickly. Your server might be unavailable.';
    } else if (timeoutSeconds < 60) {
      return '${baseContext}Request timed out after $attempts attempt${attempts > 1 ? 's' : ''}. '
          'Try checking your connection or using slower timeout settings.';
    } else {
      return '${baseContext}Request timed out after ${timeoutSeconds}s. '
          'Your connection appears to be very slow. Consider using the "Slow Connection" preset.';
    }
  }

  static String _getConnectionMessage(
      NetworkConnectionException error, String baseContext) {
    final attempts = error.attemptsMade;

    return '${baseContext}Failed to connect after $attempts attempt${attempts > 1 ? 's' : ''}. '
        'Please check your server URL and internet connection.';
  }

  static String _getSocketExceptionMessage(
      SocketException error, String baseContext) {
    switch (error.osError?.errorCode) {
      case 7: // No address associated with hostname
        return '${baseContext}Cannot find server. Please check your server URL.';
      case 61: // Connection refused
        return '${baseContext}Server refused connection. Please check your server URL and port.';
      case 64: // Host is down
        return '${baseContext}Server is currently unavailable. Please try again later.';
      case 65: // No route to host
        return '${baseContext}Cannot reach server. Please check your internet connection.';
      default:
        final message = error.message.toLowerCase();
        if (message.contains('timeout')) {
          return '${baseContext}Connection timed out. Please check your internet connection.';
        } else if (message.contains('refused')) {
          return '${baseContext}Connection refused by server. Please check your server settings.';
        } else {
          return '${baseContext}Connection failed: ${error.message}';
        }
    }
  }

  static String _getHttpExceptionMessage(
      HttpException error, String baseContext) {
    final message = error.message.toLowerCase();

    if (message.contains('500')) {
      return '${baseContext}Server error (500). Please try again later.';
    } else if (message.contains('502')) {
      return '${baseContext}Bad gateway (502). Server may be temporarily unavailable.';
    } else if (message.contains('503')) {
      return '${baseContext}Service unavailable (503). Server is temporarily overloaded.';
    } else if (message.contains('504')) {
      return '${baseContext}Gateway timeout (504). Server took too long to respond.';
    } else if (message.contains('timeout')) {
      return '${baseContext}Request timed out. Please try again.';
    } else {
      return '${baseContext}HTTP error: ${error.message}';
    }
  }

  /// Get suggestions for improving network performance based on error type
  static List<String> getSuggestions(Object error) {
    final suggestions = <String>[];

    if (error is NetworkTimeoutException) {
      if (error.totalDuration.inSeconds > 60) {
        suggestions.addAll([
          'Try the "Slow Connection" timeout preset',
          'Check if your internet connection is stable',
          'Consider using a different network (WiFi vs mobile data)',
        ]);
      } else {
        suggestions.addAll([
          'Check your server URL and credentials',
          'Verify your server is running and accessible',
          'Try again in a few moments',
        ]);
      }
    }

    if (error is NetworkConnectionException || error is SocketException) {
      suggestions.addAll([
        'Verify your server URL is correct',
        'Check that your server uses HTTPS',
        'Ensure your internet connection is working',
        'Check if your server is behind a firewall',
      ]);
    }

    if (error.toString().toLowerCase().contains('timeout')) {
      suggestions.addAll([
        'Increase timeout values in settings',
        'Try using a faster internet connection',
        'Check server performance and load',
      ]);
    }

    // Always include these general suggestions
    suggestions.addAll([
      'Try again later',
      'Contact your server administrator if problems persist',
    ]);

    return suggestions.take(4).toList(); // Limit to 4 suggestions
  }

  /// Get recommended network configuration based on error patterns
  static NetworkConfig? getRecommendedConfig(List<Object> recentErrors) {
    if (recentErrors.isEmpty) return null;

    var timeoutErrors = 0;
    var connectionErrors = 0;
    var slowErrors = 0;

    for (final error in recentErrors) {
      if (error is NetworkTimeoutException) {
        timeoutErrors++;
        if (error.totalDuration.inSeconds > 30) slowErrors++;
      } else if (error is NetworkConnectionException ||
          error is SocketException) {
        connectionErrors++;
      }
    }

    final totalErrors = recentErrors.length;
    final timeoutRate = timeoutErrors / totalErrors;
    final connectionRate = connectionErrors / totalErrors;
    final slowRate = slowErrors / totalErrors;

    // If most errors are slow timeouts, recommend slow config
    if (slowRate > 0.5 || (timeoutRate > 0.6 && slowRate > 0.3)) {
      return NetworkConfig.slowConfig;
    }

    // If mostly connection errors but some succeed, try fast config
    if (connectionRate > 0.7 && timeoutRate < 0.3) {
      return NetworkConfig.fastConfig;
    }

    // Mixed errors or mostly timeouts - stick with default
    return NetworkConfig.defaultConfig;
  }

  /// Format error for logging while keeping user message separate
  static String formatErrorForLogging(Object error, StackTrace? stackTrace) {
    final buffer = StringBuffer();
    buffer.writeln('Network Error Details:');
    buffer.writeln('Type: ${error.runtimeType}');
    buffer.writeln('Message: $error');

    if (error is NetworkTimeoutException) {
      buffer.writeln('Attempts: ${error.attemptsMade}');
      buffer.writeln('Total Duration: ${error.totalDuration}');
      if (error.originalError != null) {
        buffer.writeln('Original Error: ${error.originalError}');
      }
    }

    if (error is NetworkConnectionException) {
      buffer.writeln('Attempts: ${error.attemptsMade}');
      if (error.originalError != null) {
        buffer.writeln('Original Error: ${error.originalError}');
      }
    }

    if (stackTrace != null) {
      buffer.writeln('Stack Trace:');
      buffer.writeln(stackTrace.toString());
    }

    return buffer.toString();
  }
}
