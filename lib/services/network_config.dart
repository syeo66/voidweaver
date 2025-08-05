import 'dart:io';
import 'dart:math' as math;

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

    // Handle our custom network exceptions
    if (error is NetworkTimeoutException) {
      return enableRetryOnTimeout;
    }

    if (error is NetworkConnectionException) {
      return enableRetryOnConnectionError;
    }

    if (error is SocketException) {
      // Connection errors - usually worth retrying
      return enableRetryOnConnectionError;
    }

    if (error is HttpException) {
      final message = error.message.toLowerCase();
      if (message.contains('timeout') || message.contains('timed out')) {
        return enableRetryOnTimeout;
      }

      // Check for specific HTTP status codes that are retryable
      if (message.contains('500') || // Internal Server Error
          message.contains('502') || // Bad Gateway
          message.contains('503') || // Service Unavailable
          message.contains('504')) {
        // Gateway Timeout
        return true;
      }
    }

    if (error.toString().toLowerCase().contains('timeout')) {
      return enableRetryOnTimeout;
    }

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
          Duration(milliseconds: json['connectionTimeout'] ?? 15000),
      requestTimeout: Duration(milliseconds: json['requestTimeout'] ?? 30000),
      metadataTimeout: Duration(milliseconds: json['metadataTimeout'] ?? 20000),
      streamingTimeout:
          Duration(milliseconds: json['streamingTimeout'] ?? 60000),
      maxRetryAttempts: json['maxRetryAttempts'] ?? 3,
      initialRetryDelay:
          Duration(milliseconds: json['initialRetryDelay'] ?? 500),
      retryBackoffMultiplier: json['retryBackoffMultiplier']?.toDouble() ?? 2.0,
      maxRetryDelay: Duration(milliseconds: json['maxRetryDelay'] ?? 10000),
      enableRetryOnTimeout: json['enableRetryOnTimeout'] ?? true,
      enableRetryOnConnectionError:
          json['enableRetryOnConnectionError'] ?? true,
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
