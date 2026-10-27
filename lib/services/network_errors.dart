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

    if (error is HttpStatusException) {
      return _getHttpStatusMessage(error, baseContext);
    }

    if (error is TlsException) {
      return '${baseContext}Secure connection failed. Please check that the server has a valid certificate.';
    }

    if (error is XmlException) {
      return '${baseContext}The server sent an unexpected response. Please check your server URL.';
    }

    if (isTimeoutError(error)) {
      return '${baseContext}Request timed out. Please check your connection and try again.';
    }

    if (error is SocketException) {
      return '$baseContext${_socketErrorMessage(error) ?? 'Connection failed: ${error.message}'}';
    }

    if (isConnectionError(error)) {
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
    final original = error.originalError;
    final specific =
        original is SocketException ? _socketErrorMessage(original) : null;
    if (specific != null) return '$baseContext$specific';

    final attempts = error.attemptsMade;

    return '${baseContext}Failed to connect after $attempts attempt${attempts > 1 ? 's' : ''}. '
        'Please check your server URL and internet connection.';
  }

  /// A message for the socket errors whose cause is known, null for others.
  static String? _socketErrorMessage(SocketException error) {
    switch (error.osError?.errorCode) {
      case SocketErrorCodes.lookupNoData:
      case SocketErrorCodes.lookupNoName:
        return 'Cannot find server. Please check your internet connection and server URL.';
      case SocketErrorCodes.connectionRefused:
        return 'Server refused connection. Please check your server URL and port.';
      case SocketErrorCodes.hostDown:
        return 'Server is currently unavailable. Please try again later.';
      case SocketErrorCodes.hostUnreachable:
      case SocketErrorCodes.networkUnreachable:
        return 'Cannot reach server. Please check your internet connection.';
      case SocketErrorCodes.connectionReset:
        return 'The connection to the server was interrupted. Please try again.';
      case SocketErrorCodes.timedOut:
        return 'Connection timed out. Please check your internet connection.';
      default:
        return null;
    }
  }

  static String _getHttpStatusMessage(
      HttpStatusException error, String baseContext) {
    switch (error.statusCode) {
      case 500:
        return '${baseContext}Server error (500). Please try again later.';
      case 502:
        return '${baseContext}Bad gateway (502). Server may be temporarily unavailable.';
      case 503:
        return '${baseContext}Service unavailable (503). Server is temporarily overloaded.';
      case 504:
        return '${baseContext}Gateway timeout (504). Server took too long to respond.';
      default:
        return '${baseContext}The server returned an error (HTTP ${error.statusCode}).';
    }
  }
}
