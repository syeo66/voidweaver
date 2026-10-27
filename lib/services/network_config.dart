import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:http2/transport.dart' as http2;

/// Network timeout and retry configuration for different types of requests
class NetworkConfig {
  final Duration connectionTimeout;
  final Duration requestTimeout;
  final Duration metadataTimeout;
  final Duration streamingTimeout;
  final int maxRetryAttempts;
  final Duration initialRetryDelay;
  final double retryBackoffMultiplier;
  final Duration maxRetryDelay;
  final bool enableRetryOnTimeout;
  final bool enableRetryOnConnectionError;

  const NetworkConfig({
    this.connectionTimeout = const Duration(seconds: 15),
    this.requestTimeout = const Duration(seconds: 30),
    this.metadataTimeout = const Duration(seconds: 20),
    this.streamingTimeout = const Duration(seconds: 60),
    this.maxRetryAttempts = 3,
    this.initialRetryDelay = const Duration(milliseconds: 500),
    this.retryBackoffMultiplier = 2.0,
    this.maxRetryDelay = const Duration(seconds: 10),
    this.enableRetryOnTimeout = true,
    this.enableRetryOnConnectionError = true,
  });

  /// Default configuration for most users
  static const NetworkConfig defaultConfig = NetworkConfig();

  /// Fast configuration for good connections
  static const NetworkConfig fastConfig = NetworkConfig(
    connectionTimeout: Duration(seconds: 10),
    requestTimeout: Duration(seconds: 20),
    metadataTimeout: Duration(seconds: 15),
    streamingTimeout: Duration(seconds: 45),
    maxRetryAttempts: 2,
    initialRetryDelay: Duration(milliseconds: 300),
  );

  /// Slow configuration for poor connections
  static const NetworkConfig slowConfig = NetworkConfig(
    connectionTimeout: Duration(seconds: 30),
    requestTimeout: Duration(seconds: 60),
    metadataTimeout: Duration(seconds: 45),
    streamingTimeout: Duration(seconds: 120),
    maxRetryAttempts: 5,
    initialRetryDelay: Duration(milliseconds: 1000),
    maxRetryDelay: Duration(seconds: 30),
  );

  /// Calculate retry delay for a given attempt using exponential backoff
  Duration calculateRetryDelay(int attemptNumber) {
    if (attemptNumber <= 0) return initialRetryDelay;

    final exponentialDelay = initialRetryDelay.inMilliseconds *
        math.pow(retryBackoffMultiplier, attemptNumber - 1);

    final clampedDelay =
        math.min(exponentialDelay, maxRetryDelay.inMilliseconds.toDouble());

    // Add jitter to prevent thundering herd effect
    final jitter = math.Random().nextDouble() * 0.1; // 10% jitter
    final finalDelay = clampedDelay * (1.0 + jitter);

    return Duration(milliseconds: finalDelay.round());
  }

  /// Determine if an error should be retried
  bool shouldRetry(Object error, int attemptNumber) {
    if (attemptNumber >= maxRetryAttempts) return false;

    if (isTimeoutError(error)) return enableRetryOnTimeout;
    if (isConnectionError(error)) return enableRetryOnConnectionError;
    if (error is HttpStatusException) return error.isTransient;

    return false;
  }

  /// Get timeout for specific request type
  Duration getTimeoutForRequestType(NetworkRequestType type) {
    switch (type) {
      case NetworkRequestType.connection:
        return connectionTimeout;
      case NetworkRequestType.metadata:
        return metadataTimeout;
      case NetworkRequestType.streaming:
        return streamingTimeout;
      case NetworkRequestType.general:
        return requestTimeout;
    }
  }

  NetworkConfig copyWith({
    Duration? connectionTimeout,
    Duration? requestTimeout,
    Duration? metadataTimeout,
    Duration? streamingTimeout,
    int? maxRetryAttempts,
    Duration? initialRetryDelay,
    double? retryBackoffMultiplier,
    Duration? maxRetryDelay,
    bool? enableRetryOnTimeout,
    bool? enableRetryOnConnectionError,
  }) {
    return NetworkConfig(
      connectionTimeout: connectionTimeout ?? this.connectionTimeout,
      requestTimeout: requestTimeout ?? this.requestTimeout,
      metadataTimeout: metadataTimeout ?? this.metadataTimeout,
      streamingTimeout: streamingTimeout ?? this.streamingTimeout,
      maxRetryAttempts: maxRetryAttempts ?? this.maxRetryAttempts,
      initialRetryDelay: initialRetryDelay ?? this.initialRetryDelay,
      retryBackoffMultiplier:
          retryBackoffMultiplier ?? this.retryBackoffMultiplier,
      maxRetryDelay: maxRetryDelay ?? this.maxRetryDelay,
      enableRetryOnTimeout: enableRetryOnTimeout ?? this.enableRetryOnTimeout,
      enableRetryOnConnectionError:
          enableRetryOnConnectionError ?? this.enableRetryOnConnectionError,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'connectionTimeout': connectionTimeout.inMilliseconds,
      'requestTimeout': requestTimeout.inMilliseconds,
      'metadataTimeout': metadataTimeout.inMilliseconds,
      'streamingTimeout': streamingTimeout.inMilliseconds,
      'maxRetryAttempts': maxRetryAttempts,
      'initialRetryDelay': initialRetryDelay.inMilliseconds,
      'retryBackoffMultiplier': retryBackoffMultiplier,
      'maxRetryDelay': maxRetryDelay.inMilliseconds,
      'enableRetryOnTimeout': enableRetryOnTimeout,
      'enableRetryOnConnectionError': enableRetryOnConnectionError,
    };
  }

  factory NetworkConfig.fromJson(Map<String, dynamic> json) {
    return NetworkConfig(
      connectionTimeout:
          Duration(milliseconds: json['connectionTimeout'] as int? ?? 15000),
      requestTimeout:
          Duration(milliseconds: json['requestTimeout'] as int? ?? 30000),
      metadataTimeout:
          Duration(milliseconds: json['metadataTimeout'] as int? ?? 20000),
      streamingTimeout:
          Duration(milliseconds: json['streamingTimeout'] as int? ?? 60000),
      maxRetryAttempts: json['maxRetryAttempts'] as int? ?? 3,
      initialRetryDelay:
          Duration(milliseconds: json['initialRetryDelay'] as int? ?? 500),
      retryBackoffMultiplier:
          (json['retryBackoffMultiplier'] as num?)?.toDouble() ?? 2.0,
      maxRetryDelay:
          Duration(milliseconds: json['maxRetryDelay'] as int? ?? 10000),
      enableRetryOnTimeout: json['enableRetryOnTimeout'] as bool? ?? true,
      enableRetryOnConnectionError:
          json['enableRetryOnConnectionError'] as bool? ?? true,
    );
  }

  @override
  String toString() {
    return 'NetworkConfig(connection: ${connectionTimeout.inSeconds}s, '
        'request: ${requestTimeout.inSeconds}s, '
        'retries: $maxRetryAttempts)';
  }
}

/// Types of network requests for timeout selection
enum NetworkRequestType {
  connection,
  metadata,
  streaming,
  general,
}

/// Exception thrown when network request times out after all retries
class NetworkTimeoutException implements Exception {
  final String message;
  final int attemptsMade;
  final Duration totalDuration;
  final Object? originalError;

  const NetworkTimeoutException(
    this.message, {
    required this.attemptsMade,
    required this.totalDuration,
    this.originalError,
  });

  @override
  String toString() {
    return 'NetworkTimeoutException: $message '
        '($attemptsMade attempts over ${totalDuration.inSeconds}s)';
  }
}

/// Exception thrown when network request fails due to connection issues
class NetworkConnectionException implements Exception {
  final String message;
  final int attemptsMade;
  final Object? originalError;

  const NetworkConnectionException(
    this.message, {
    required this.attemptsMade,
    this.originalError,
  });

  @override
  String toString() {
    return 'NetworkConnectionException: $message ($attemptsMade attempts)';
  }
}

/// A response with a status other than 200.
class HttpStatusException implements Exception {
  final int statusCode;

  const HttpStatusException(this.statusCode);

  /// Server and gateway errors that may go away on a retry.
  bool get isTransient => const {500, 502, 503, 504}.contains(statusCode);

  @override
  String toString() => 'HTTP $statusCode';
}

/// [SocketException.osError] codes on Android: Linux errno values, and
/// getaddrinfo's for failed lookups. macOS and iOS use other numbers.
abstract final class SocketErrorCodes {
  /// EAI_NODATA, "No address associated with hostname". Also what a lookup
  /// fails with while the device is offline.
  static const lookupNoData = 7;
  static const lookupNoName = 8; // EAI_NONAME
  static const networkUnreachable = 101; // ENETUNREACH
  static const connectionReset = 104; // ECONNRESET
  static const timedOut = 110; // ETIMEDOUT
  static const connectionRefused = 111; // ECONNREFUSED
  static const hostDown = 112; // EHOSTDOWN
  static const hostUnreachable = 113; // EHOSTUNREACH
}

// The checks below go by the error's type and code, never its message, which
// can contain anything (e.g. a host name).

/// Whether [error] is a timeout.
bool isTimeoutError(Object error) =>
    error is TimeoutException ||
    error is NetworkTimeoutException ||
    (error is SocketException &&
        error.osError?.errorCode == SocketErrorCodes.timedOut);

/// Whether [error] means the connection couldn't be made or broke off.
/// `http.ClientException` comes from the HTTP/1.1 client (and implements
/// [SocketException] when caused by one), `TransportException` from HTTP/2.
bool isConnectionError(Object error) =>
    !isTimeoutError(error) &&
    (error is NetworkConnectionException ||
        error is SocketException ||
        error is http.ClientException ||
        error is http2.TransportException);
