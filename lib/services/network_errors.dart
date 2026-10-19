import 'dart:io';
import 'package:xml/xml.dart';
import 'network_config.dart';
import 'subsonic_api.dart';

/// An error whose message can be shown to the user as it is, e.g. an album
/// without songs.
class UserFacingException implements Exception {
  final String message;

  const UserFacingException(this.message);

  @override
  String toString() => message;
}

/// Helper class for converting exceptions to user-friendly messages
class NetworkErrorHelper {
  /// Converts [error] to a message for the user, prefixed with [context]
  /// (e.g. "Failed to play album"). Show errors through this rather than
  /// their `toString()`.
  static String getErrorMessage(Object error, {String? context}) {
    final baseContext = context != null ? '$context: ' : '';

    if (error is UserFacingException) {
      return '$baseContext${error.message}';
    }

    if (error is SubsonicException) {
      return error.isAuthError
          ? '${baseContext}Wrong username or password.'
          : '${baseContext}The server reported an error: ${error.message}';
    }

    if (error is ArgumentError && error.message is String) {
      return '$baseContext${error.message}';
    }

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

    if (error is TlsException) {
      return '${baseContext}Secure connection failed. Please check that the server has a valid certificate.';
    }

    if (error is XmlException) {
      return '${baseContext}The server sent an unexpected response. Please check your server URL.';
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

    return '${baseContext}Something went wrong. Please try again.';
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
}
