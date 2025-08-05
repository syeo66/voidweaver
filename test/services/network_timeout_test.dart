import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

import 'package:voidweaver/services/network_config.dart';
import 'package:voidweaver/services/network_errors.dart';
import 'package:voidweaver/services/settings_service.dart';

void main() {
  group('NetworkConfig', () {
    test('should have sensible default values', () {
      const config = NetworkConfig.defaultConfig;

      expect(config.connectionTimeout, const Duration(seconds: 15));
      expect(config.requestTimeout, const Duration(seconds: 30));
      expect(config.metadataTimeout, const Duration(seconds: 20));
      expect(config.streamingTimeout, const Duration(seconds: 60));
      expect(config.maxRetryAttempts, 3);
      expect(config.enableRetryOnTimeout, true);
      expect(config.enableRetryOnConnectionError, true);
    });

    test('should provide fast and slow presets', () {
      const fast = NetworkConfig.fastConfig;
      const slow = NetworkConfig.slowConfig;

      expect(fast.connectionTimeout.inSeconds,
          lessThan(NetworkConfig.defaultConfig.connectionTimeout.inSeconds));
      expect(slow.connectionTimeout.inSeconds,
          greaterThan(NetworkConfig.defaultConfig.connectionTimeout.inSeconds));

      expect(fast.maxRetryAttempts,
          lessThanOrEqualTo(NetworkConfig.defaultConfig.maxRetryAttempts));
      expect(slow.maxRetryAttempts,
          greaterThanOrEqualTo(NetworkConfig.defaultConfig.maxRetryAttempts));
    });

    test('should calculate retry delay with exponential backoff', () {
      const config = NetworkConfig.defaultConfig;

      final delay1 = config.calculateRetryDelay(1);
      final delay2 = config.calculateRetryDelay(2);
      final delay3 = config.calculateRetryDelay(3);

      // First delay should be close to initial delay (with jitter)
      expect(delay1.inMilliseconds,
          closeTo(config.initialRetryDelay.inMilliseconds, 100));
      expect(delay2.inMilliseconds,
          greaterThan(delay1.inMilliseconds * 0.8)); // Account for jitter
      expect(delay3.inMilliseconds,
          greaterThan(delay2.inMilliseconds * 0.8)); // Account for jitter

      // Should not exceed max delay (with 10% jitter)
      final maxDelay = config.calculateRetryDelay(10);
      expect(maxDelay.inMilliseconds,
          lessThanOrEqualTo(config.maxRetryDelay.inMilliseconds * 1.1));
    });

    test('should determine retryable errors correctly', () {
      const config = NetworkConfig.defaultConfig;

      // Timeout errors should be retryable
      expect(
          config.shouldRetry(TimeoutException('test', Duration.zero), 1), true);
      expect(
          config.shouldRetry(
              NetworkTimeoutException('test',
                  attemptsMade: 1, totalDuration: Duration.zero),
              1),
          true);

      // Connection errors should be retryable
      expect(config.shouldRetry(const SocketException('Connection refused'), 1),
          true);
      expect(
          config.shouldRetry(
              NetworkConnectionException('test', attemptsMade: 1), 1),
          true);

      // Should not retry after max attempts
      expect(
          config.shouldRetry(
              TimeoutException('test', Duration.zero), config.maxRetryAttempts),
          false);

      // Should not retry non-retryable errors
      expect(config.shouldRetry(const FormatException('Bad format'), 1), false);
    });

    test('should serialize to/from JSON correctly', () {
      const original = NetworkConfig(
        connectionTimeout: Duration(seconds: 10),
        requestTimeout: Duration(seconds: 25),
        maxRetryAttempts: 5,
        enableRetryOnTimeout: false,
      );

      final json = original.toJson();
      final restored = NetworkConfig.fromJson(json);

      expect(restored.connectionTimeout, original.connectionTimeout);
      expect(restored.requestTimeout, original.requestTimeout);
      expect(restored.maxRetryAttempts, original.maxRetryAttempts);
      expect(restored.enableRetryOnTimeout, original.enableRetryOnTimeout);
    });

    test('should get timeout for specific request types', () {
      const config = NetworkConfig.defaultConfig;

      expect(config.getTimeoutForRequestType(NetworkRequestType.connection),
          config.connectionTimeout);
      expect(config.getTimeoutForRequestType(NetworkRequestType.metadata),
          config.metadataTimeout);
      expect(config.getTimeoutForRequestType(NetworkRequestType.streaming),
          config.streamingTimeout);
      expect(config.getTimeoutForRequestType(NetworkRequestType.general),
          config.requestTimeout);
    });
  });

  // Note: NetworkRetryService integration tests would require
  // a test server or sophisticated HTTP mocking setup. The core retry logic
  // is tested through the NetworkConfig tests above.

  group('NetworkErrorHelper', () {
    test('should provide user-friendly messages for timeout errors', () {
      final error = NetworkTimeoutException(
        'Request timed out',
        attemptsMade: 3,
        totalDuration: const Duration(seconds: 45),
      );

      final message =
          NetworkErrorHelper.getErrorMessage(error, context: 'Loading albums');

      expect(message, contains('Loading albums'));
      expect(message, contains('timed out'));
      expect(message, contains('3 attempts'));
    });

    test('should provide user-friendly messages for connection errors', () {
      final error = NetworkConnectionException(
        'Connection failed',
        attemptsMade: 2,
      );

      final message = NetworkErrorHelper.getErrorMessage(error);

      expect(message, contains('Failed to connect'));
      expect(message, contains('2 attempts'));
      expect(message, contains('server URL'));
    });

    test('should provide user-friendly messages for socket errors', () {
      const error = SocketException('Connection refused',
          osError: OSError('Connection refused', 61));

      final message = NetworkErrorHelper.getErrorMessage(error);

      expect(message, contains('Server refused connection'));
      expect(message, contains('server URL'));
    });

    test('should provide suggestions based on error type', () {
      final timeoutError = NetworkTimeoutException(
        'Request timed out',
        attemptsMade: 3,
        totalDuration: const Duration(seconds: 90),
      );

      final suggestions = NetworkErrorHelper.getSuggestions(timeoutError);

      expect(suggestions, isNotEmpty);
      expect(suggestions.any((s) => s.contains('Slow Connection')), true);
      expect(suggestions.length, lessThanOrEqualTo(4));
    });

    test('should recommend network config based on error patterns', () {
      final slowTimeoutErrors = List.generate(
          5,
          (i) => NetworkTimeoutException(
                'timeout',
                attemptsMade: 1,
                totalDuration: const Duration(seconds: 60),
              ));

      final recommendedConfig =
          NetworkErrorHelper.getRecommendedConfig(slowTimeoutErrors);

      expect(recommendedConfig, NetworkConfig.slowConfig);
    });

    test('should format errors for logging with detailed information', () {
      final error = NetworkTimeoutException(
        'Request timed out',
        attemptsMade: 3,
        totalDuration: const Duration(seconds: 45),
        originalError: TimeoutException('inner timeout', Duration.zero),
      );

      final logMessage =
          NetworkErrorHelper.formatErrorForLogging(error, StackTrace.current);

      expect(logMessage, contains('NetworkTimeoutException'));
      expect(logMessage, contains('Attempts: 3'));
      expect(logMessage, contains('Total Duration'));
      expect(logMessage, contains('Original Error'));
      expect(logMessage, contains('Stack Trace'));
    });
  });

  group('SettingsService Network Integration', () {
    late SettingsService settingsService;

    setUp(() {
      settingsService = SettingsService();
    });

    test('should initialize with default network config', () {
      expect(settingsService.networkConfig, NetworkConfig.defaultConfig);
    });

    test('should update network configuration', () async {
      const newConfig = NetworkConfig(
        connectionTimeout: Duration(seconds: 20),
        maxRetryAttempts: 5,
      );

      await settingsService.setNetworkConfig(newConfig);

      expect(settingsService.networkConfig.connectionTimeout,
          const Duration(seconds: 20));
      expect(settingsService.networkConfig.maxRetryAttempts, 5);
    });

    test('should update specific timeout values', () async {
      await settingsService.updateTimeouts(
        connectionTimeout: const Duration(seconds: 25),
        requestTimeout: const Duration(seconds: 45),
      );

      expect(settingsService.networkConfig.connectionTimeout,
          const Duration(seconds: 25));
      expect(settingsService.networkConfig.requestTimeout,
          const Duration(seconds: 45));
      // Other values should remain unchanged
      expect(settingsService.networkConfig.maxRetryAttempts,
          NetworkConfig.defaultConfig.maxRetryAttempts);
    });

    test('should update retry settings', () async {
      await settingsService.updateRetrySettings(
        maxRetryAttempts: 7,
        enableRetryOnTimeout: false,
      );

      expect(settingsService.networkConfig.maxRetryAttempts, 7);
      expect(settingsService.networkConfig.enableRetryOnTimeout, false);
      // Other values should remain unchanged
      expect(settingsService.networkConfig.connectionTimeout,
          NetworkConfig.defaultConfig.connectionTimeout);
    });

    test('should set preset configurations', () async {
      await settingsService.setNetworkConfigToFast();
      expect(settingsService.networkConfig, NetworkConfig.fastConfig);

      await settingsService.setNetworkConfigToSlow();
      expect(settingsService.networkConfig, NetworkConfig.slowConfig);

      await settingsService.resetNetworkConfigToDefault();
      expect(settingsService.networkConfig, NetworkConfig.defaultConfig);
    });
  });

  group('Network Exception Types', () {
    test('NetworkTimeoutException should contain relevant information', () {
      const error = NetworkTimeoutException(
        'Test timeout',
        attemptsMade: 3,
        totalDuration: Duration(seconds: 30),
        originalError: 'Inner error',
      );

      expect(error.message, 'Test timeout');
      expect(error.attemptsMade, 3);
      expect(error.totalDuration, const Duration(seconds: 30));
      expect(error.originalError, 'Inner error');
      expect(error.toString(), contains('NetworkTimeoutException'));
      expect(error.toString(), contains('3 attempts'));
      expect(error.toString(), contains('30s'));
    });

    test('NetworkConnectionException should contain relevant information', () {
      const error = NetworkConnectionException(
        'Test connection error',
        attemptsMade: 2,
        originalError: 'Inner error',
      );

      expect(error.message, 'Test connection error');
      expect(error.attemptsMade, 2);
      expect(error.originalError, 'Inner error');
      expect(error.toString(), contains('NetworkConnectionException'));
      expect(error.toString(), contains('2 attempts'));
    });
  });
}
