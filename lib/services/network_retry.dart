import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'network_config.dart';

final _log = Logger('network');

/// Service for handling network requests with timeout and retry logic
class NetworkRetryService {
  final NetworkConfig config;
  final http.Client _httpClient;

  NetworkRetryService({required this.config, required this._httpClient});

  /// Execute an HTTP GET request with retry logic and timeout handling.
  /// Without [retry] the request is sent once: for requests that aren't safe
  /// to repeat, because a timeout doesn't tell whether the server got them.
  ///
  /// A response other than 2xx is an [HttpStatusException]: a server or
  /// gateway error (e.g. 502 while the server restarts) is retried like a
  /// timeout, see [NetworkConfig.shouldRetry]. A request that times out is
  /// aborted, so it doesn't keep its connection open.
  Future<http.Response> getWithRetry(
    Uri uri, {
    Map<String, String>? headers,
    NetworkRequestType requestType = NetworkRequestType.general,
    String? contextDescription,
    bool retry = true,
  }) async {
    return _executeWithRetry(
      (abortTrigger) async {
        final request = http.AbortableRequest(
          'GET',
          uri,
          abortTrigger: abortTrigger,
        );
        if (headers != null) request.headers.addAll(headers);
        // The body is read inside the attempt, so the timeout covers it
        final response = await http.Response.fromStream(
          await _httpClient.send(request),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpStatusException(response.statusCode);
        }
        return response;
      },
      requestType: requestType,
      contextDescription: contextDescription ?? 'GET $uri',
      maxAttempts: retry ? config.maxRetryAttempts : 1,
    );
  }

  /// Execute any HTTP request with retry logic and timeout handling
  Future<http.Response> _executeWithRetry(
    Future<http.Response> Function(Future<void> abortTrigger) request, {
    required NetworkRequestType requestType,
    required String contextDescription,
    required int maxAttempts,
  }) async {
    final stopwatch = Stopwatch()..start();
    Object? lastError;
    int attemptNumber = 0;

    while (attemptNumber < maxAttempts) {
      attemptNumber++;

      try {
        _log.fine(
          'Network request attempt $attemptNumber/$maxAttempts: $contextDescription',
        );

        final response = await _executeWithTimeout(request, requestType);

        _log.fine(
          'Network request succeeded on attempt $attemptNumber: $contextDescription (${response.statusCode})',
        );

        return response;
      } catch (error) {
        lastError = error;

        _log.warning(
          'Network request failed on attempt $attemptNumber: $contextDescription',
          error,
        );

        // Check if we should retry this error
        if (attemptNumber >= maxAttempts ||
            !config.shouldRetry(error, attemptNumber)) {
          _log.fine('Not retrying error', error);
          break;
        }

        // Don't wait after the last attempt
        if (attemptNumber < maxAttempts) {
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

  /// Execute a request with timeout handling. On a timeout the request is
  /// aborted: `Future.timeout` alone only stops waiting for it.
  Future<http.Response> _executeWithTimeout(
    Future<http.Response> Function(Future<void> abortTrigger) request,
    NetworkRequestType requestType,
  ) async {
    final timeout = config.getTimeoutForRequestType(requestType);
    final abort = Completer<void>();

    try {
      return await request(abort.future).timeout(timeout);
    } on TimeoutException catch (e) {
      abort.complete();
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
