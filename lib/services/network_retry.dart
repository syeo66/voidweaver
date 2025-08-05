import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http_plus/http_plus.dart' as http_plus;
import 'network_config.dart';

/// Service for handling network requests with timeout and retry logic
class NetworkRetryService {
  final NetworkConfig config;
  final http_plus.HttpPlusClient _httpClient;

  NetworkRetryService({
    required this.config,
    required http_plus.HttpPlusClient httpClient,
  }) : _httpClient = httpClient;

  /// Execute an HTTP GET request with retry logic and timeout handling
  Future<dynamic> getWithRetry(
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

  /// Execute an HTTP POST request with retry logic and timeout handling
  Future<dynamic> postWithRetry(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    NetworkRequestType requestType = NetworkRequestType.general,
    String? contextDescription,
  }) async {
    return _executeWithRetry(
      () => _httpClient.post(uri, headers: headers, body: body),
      requestType: requestType,
      contextDescription: contextDescription ?? 'POST $uri',
    );
  }

  /// Execute any HTTP request with retry logic and timeout handling
  Future<dynamic> _executeWithRetry(
    Future<dynamic> Function() request, {
    required NetworkRequestType requestType,
    required String contextDescription,
  }) async {
    final stopwatch = Stopwatch()..start();
    Object? lastError;
    int attemptNumber = 0;

    while (attemptNumber < config.maxRetryAttempts) {
      attemptNumber++;

      try {
        if (kDebugMode) {
          debugPrint(
              'Network request attempt $attemptNumber/$config.maxRetryAttempts: $contextDescription');
        }

        final response = await _executeWithTimeout(request, requestType);

        if (kDebugMode) {
          debugPrint(
              'Network request succeeded on attempt $attemptNumber: $contextDescription (${response.statusCode})');
        }

        return response;
      } catch (error) {
        lastError = error;

        if (kDebugMode) {
          debugPrint(
              'Network request failed on attempt $attemptNumber: $contextDescription - $error');
        }

        // Check if we should retry this error
        if (!config.shouldRetry(error, attemptNumber)) {
          if (kDebugMode) {
            debugPrint('Not retrying error: $error');
          }
          break;
        }

        // Don't wait after the last attempt
        if (attemptNumber < config.maxRetryAttempts) {
          final retryDelay = config.calculateRetryDelay(attemptNumber);

          if (kDebugMode) {
            debugPrint('Retrying in ${retryDelay.inMilliseconds}ms...');
          }

          await Future.delayed(retryDelay);
        }
      }
    }

    stopwatch.stop();

    // All retries exhausted, throw appropriate exception
    if (lastError != null) {
      if (_isTimeoutError(lastError)) {
        throw NetworkTimeoutException(
          'Request timed out after $attemptNumber attempts: $contextDescription',
          attemptsMade: attemptNumber,
          totalDuration: stopwatch.elapsed,
          originalError: lastError,
        );
      } else if (_isConnectionError(lastError)) {
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
  Future<dynamic> _executeWithTimeout(
    Future<dynamic> Function() request,
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

  /// Check if error is timeout-related
  bool _isTimeoutError(Object error) {
    if (error is TimeoutException) return true;
    if (error is NetworkTimeoutException) return true;
    if (error is SocketException) {
      final message = error.message.toLowerCase();
      return message.contains('timeout') || message.contains('timed out');
    }
    if (error is HttpException) {
      final message = error.message.toLowerCase();
      return message.contains('timeout') || message.contains('timed out');
    }
    return error.toString().toLowerCase().contains('timeout');
  }

  /// Check if error is connection-related
  bool _isConnectionError(Object error) {
    if (error is SocketException) {
      // Common socket error types that indicate connection issues
      return error.osError?.errorCode ==
              7 || // No address associated with hostname
          error.osError?.errorCode == 61 || // Connection refused
          error.osError?.errorCode == 64 || // Host is down
          error.osError?.errorCode == 65 || // No route to host
          error.message.toLowerCase().contains('connection');
    }
    if (error is NetworkConnectionException) return true;
    return false;
  }

  /// Dispose resources
  void dispose() {
    // HttpPlusClient disposal is handled by the caller (SubsonicApi)
  }
}

/// Mixin to add retry capabilities to any service
mixin NetworkRetryMixin {
  NetworkRetryService? _retryService;

  /// Initialize the retry service
  void initializeRetryService(
      NetworkConfig config, http_plus.HttpPlusClient httpClient) {
    _retryService = NetworkRetryService(config: config, httpClient: httpClient);
  }

  /// Get the retry service (must be initialized first)
  NetworkRetryService get retryService {
    if (_retryService == null) {
      throw StateError(
          'NetworkRetryService not initialized. Call initializeRetryService first.');
    }
    return _retryService!;
  }

  /// Dispose the retry service
  void disposeRetryService() {
    _retryService?.dispose();
    _retryService = null;
  }
}

/// Enhanced HTTP response with retry metadata
class RetryResponse {
  final dynamic response;
  final int attemptsMade;
  final Duration totalDuration;
  final List<String> attemptErrors;

  RetryResponse({
    required this.response,
    required this.attemptsMade,
    required this.totalDuration,
    required this.attemptErrors,
  });

  // Delegate to the wrapped response
  String get body => response.body;
  int get statusCode => response.statusCode;
  Map<String, String> get headers => response.headers;
  bool get isRedirect => response.isRedirect;
  bool get persistentConnection => response.persistentConnection;
  String? get reasonPhrase => response.reasonPhrase;
  dynamic get request => response.request;

  @override
  String toString() {
    return 'RetryResponse($statusCode, attempts: $attemptsMade, '
        'duration: ${totalDuration.inMilliseconds}ms)';
  }
}
