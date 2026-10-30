import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'network_config.dart';

final _log = Logger('network');

/// Service for handling network requests with timeout and retry logic
class NetworkRetryService {
  final NetworkConfig config;
  final http.Client _httpClient;

  NetworkRetryService({
    required this.config,
    required http.Client httpClient,
  }) : _httpClient = httpClient;

  /// Execute an HTTP GET request with retry logic and timeout handling
  Future<http.Response> getWithRetry(
    Uri uri, {
    Map<String, String>? headers,
    NetworkRequestType requestType = NetworkRequestType.general,
    String? contextDescription,
  }) async {
    return _executeWithRetry(
      () => _httpClient.get(uri, headers: headers),
      requestType: requestType,
      contextDescription: contextDescription ?? 'GET $uri',
    );
  }

  /// Execute any HTTP request with retry logic and timeout handling
  Future<http.Response> _executeWithRetry(
    Future<http.Response> Function() request, {
    required NetworkRequestType requestType,
    required String contextDescription,
  }) async {
    final stopwatch = Stopwatch()..start();
    Object? lastError;
    int attemptNumber = 0;

    while (attemptNumber < config.maxRetryAttempts) {
      attemptNumber++;

      try {
        _log.fine(
            'Network request attempt $attemptNumber/${config.maxRetryAttempts}: $contextDescription');

        final response = await _executeWithTimeout(request, requestType);

        _log.fine(
            'Network request succeeded on attempt $attemptNumber: $contextDescription (${response.statusCode})');

        return response;
      } catch (error) {
        lastError = error;

        _log.warning(
            'Network request failed on attempt $attemptNumber: $contextDescription',
            error);

        // Check if we should retry this error
        if (!config.shouldRetry(error, attemptNumber)) {
          _log.fine('Not retrying error', error);
          break;
        }

        // Don't wait after the last attempt
        if (attemptNumber < config.maxRetryAttempts) {
          final retryDelay = config.calculateRetryDelay(attemptNumber);

          _log.fine('Retrying in ${retryDelay.inMilliseconds}ms...');

          await Future.delayed(retryDelay);
        }
      }
    }

    stopwatch.stop();

    // All retries exhausted, throw appropriate exception
    if (lastError != null) {
      if (isTimeoutError(lastError)) {
        throw NetworkTimeoutException(
          'Request timed out after $attemptNumber attempts: $contextDescription',
          attemptsMade: attemptNumber,
          totalDuration: stopwatch.elapsed,
          originalError: lastError,
        );
      } else if (isConnectionError(lastError)) {
        throw NetworkConnectionException(
          'Connection failed after $attemptNumber attempts: $contextDescription',
          attemptsMade: attemptNumber,
          originalError: lastError,
        );
      }
    }

    // Fallback - rethrow the last error
    if (lastError != null) {
      throw lastError;
    } else {
      throw NetworkTimeoutException(
        'Unknown network error after $attemptNumber attempts: $contextDescription',
        attemptsMade: attemptNumber,
        totalDuration: stopwatch.elapsed,
      );
    }
  }

  /// Execute a request with timeout handling
  Future<http.Response> _executeWithTimeout(
    Future<http.Response> Function() request,
    NetworkRequestType requestType,
  ) async {
    final timeout = config.getTimeoutForRequestType(requestType);

    try {
      return await request().timeout(timeout);
    } on TimeoutException catch (e) {
      throw NetworkTimeoutException(
        'Request timed out after ${timeout.inSeconds} seconds',
        attemptsMade: 1,
        totalDuration: timeout,
        originalError: e,
      );
    }
  }

  /// Dispose resources
  void dispose() {
    // The HTTP client is closed by the caller (SubsonicApi)
  }
}
