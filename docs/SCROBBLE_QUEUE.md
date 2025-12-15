# Scrobble Queue System

## Overview

The ScrobbleQueue system ensures that play count data is never lost due to network failures, temporary outages, or app restarts. It provides persistent, automatic retry logic with exponential backoff while maintaining non-blocking operation that doesn't interfere with playback functionality.

## Architecture

### Components

#### ScrobbleQueue Service
**Location**: `lib/services/scrobble_queue.dart`

The main service that manages the queue of scrobble requests with automatic retry and persistent storage.

#### ScrobbleRequest Model
```dart
class ScrobbleRequest {
  final String songId;
  final ScrobbleType type;        // nowPlaying or submission
  final DateTime? playedAt;       // Timestamp for submissions
  final DateTime queuedAt;        // When request was queued
  final int retryCount;           // Number of retry attempts
}
```

#### ScrobbleType Enum
```dart
enum ScrobbleType {
  nowPlaying,    // "Now playing" notifications
  submission,    // Play count submissions
}
```

## Features

### Persistent Storage

All scrobble requests are stored in SharedPreferences as JSON:
- Survives app restarts
- Survives crashes
- Automatic restoration on initialization
- Graceful handling of storage failures (continues in-memory)

### Automatic Retry Logic

Failed requests are automatically retried with:
- **Immediate retry**: First attempt on enqueue
- **Periodic retry**: Every 30 seconds for queued requests
- **Exponential backoff**: Increasing delays between retries
- **Maximum attempts**: 5 retries before dropping request
- **Age limit**: Requests older than 7 days are dropped

### Non-Blocking Operation

All queue operations are asynchronous and never block:
- Playback continues normally
- Skip operations unaffected
- UI remains responsive
- Background processing minimizes battery impact

### Intelligent Processing

The queue intelligently handles request processing:
- **Immediate processing**: New requests processed right away if network available
- **Batch processing**: Multiple requests processed sequentially with 100ms spacing
- **Continuous retry**: Remaining items processed after each batch
- **Network awareness**: Detects failures and queues for later

## Integration

### AudioPlayerService Integration

The ScrobbleQueue is integrated into AudioPlayerService:

```dart
class AudioPlayerService extends ChangeNotifier {
  final ScrobbleQueue _scrobbleQueue;

  AudioPlayerService(
    this._api,
    this._settingsService, {
    ScrobbleQueue? scrobbleQueue,
  }) : _scrobbleQueue = scrobbleQueue ?? ScrobbleQueue(_api) {
    _scrobbleQueue.initialize();
  }

  // Queue "now playing" notification
  void _notifyNowPlaying() {
    _scrobbleQueue.queueNowPlaying(_currentSong!.id);
  }

  // Queue play count submission
  void _scrobbleCurrentSong() {
    _scrobbleQueue.queueSubmission(
      _currentSong!.id,
      playedAt: _currentSongStartTime,
    );
  }

  @override
  void dispose() {
    _scrobbleQueue.dispose();
    super.dispose();
  }
}
```

### Scrobbling Triggers

The queue is used whenever scrobbles need to be sent:

1. **Now Playing Notifications**:
   - Sent when a song starts playing
   - Queued via `queueNowPlaying(songId)`

2. **Play Count Submissions**:
   - Sent when song reaches 50% or 2 minutes (whichever first)
   - Sent on manual completion detection
   - Sent on song completion
   - Queued via `queueSubmission(songId, playedAt: timestamp)`

## Configuration

### Constants

```dart
static const int _maxRetries = 5;                          // Maximum retry attempts
static const Duration _processingInterval = Duration(seconds: 30);  // Periodic check interval
static const Duration _maxAge = Duration(days: 7);         // Request age limit
```

### Queue Behavior

- **Storage Key**: `'scrobble_queue'` in SharedPreferences
- **Inter-Request Delay**: 100ms between sequential requests
- **Retry Strategy**: Immediate retry + periodic checks
- **Memory Management**: Automatic cleanup of old/failed requests

## Performance

### Efficiency

- **Minimal overhead**: Queue operations are fast and non-blocking
- **Battery friendly**: Batch processing reduces wake-ups
- **Memory efficient**: Automatic cleanup prevents unbounded growth
- **Network efficient**: 100ms spacing prevents server overload

### Resource Usage

- **Storage**: ~50-100 bytes per queued request
- **Memory**: Minimal in-memory queue (typically 0-5 items)
- **CPU**: Negligible (background timer + JSON serialization)
- **Network**: One HTTP request per scrobble (compressed)

## Error Handling

### Network Failures

```dart
try {
  await _sendScrobble(request);
  successfulRequests.add(request);
  debugPrint('Successfully sent ${request.type.name} for song ${request.songId}');
} catch (e) {
  debugPrint('Failed to send ${request.type.name} for song ${request.songId}: $e');
  failedRequests.add(request.copyWithRetry());
}
```

### Storage Failures

```dart
try {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_storageKey, queueJson);
} catch (e) {
  debugPrint('Error saving scrobble queue: $e');
  // Continue with in-memory queue
}
```

### Graceful Degradation

- Storage failures don't stop queue operation
- Network failures trigger retry logic
- Maximum retries prevent infinite loops
- Old requests automatically cleaned up

## Testing

### Comprehensive Test Suite

**Location**: `test/services/scrobble_queue_test.dart`

**Coverage**: 19 tests covering:

1. **Queue Management**:
   - Initialization with empty queue
   - Queue size tracking
   - Request serialization/deserialization

2. **Request Processing**:
   - Successful processing
   - Failed request retry
   - Multiple request ordering
   - Mixed request types

3. **Persistence**:
   - Queue persistence to storage
   - Queue restoration after restart
   - Storage failure handling

4. **Error Handling**:
   - Network failure retry
   - Maximum retry enforcement
   - Request age cleanup
   - Concurrent processing prevention

5. **Performance**:
   - Immediate processing on enqueue
   - Periodic processing
   - Disposal during processing
   - Empty queue handling

### Mock Infrastructure

Tests use `MockSubsonicApi` to simulate:
- Successful API calls
- Network failures
- Slow responses
- Various error conditions

## Debugging

### Debug Output

The queue provides detailed logging:

```
ScrobbleQueue initialized with 2 pending requests
Queued nowPlaying for song song123 (queue size: 1)
Processing scrobble queue (1 requests)
Successfully sent nowPlaying for song song123
Scrobble queue empty
```

### Monitoring

Check queue status:
```dart
final queueSize = scrobbleQueue.queueSize;
final isProcessing = scrobbleQueue.isProcessing;
```

### Manual Processing

Trigger immediate processing:
```dart
await scrobbleQueue.processQueue();
```

## Best Practices

### For Users

- No action required - queue works automatically
- Play counts tracked even when offline
- Queued requests processed when network returns
- Old requests (>7 days) automatically cleaned up

### For Developers

1. **Always use the queue**: Never call scrobble API directly
2. **Don't block on results**: Queue operations are fire-and-forget
3. **Test offline scenarios**: Verify queue handles network failures
4. **Monitor queue size**: Large queues may indicate connectivity issues
5. **Dispose properly**: Always dispose queue when service is destroyed

## Comparison: Before vs After

### Before (Direct API Calls)

```dart
// Direct API call - fails if network unavailable
try {
  await _api.scrobbleNowPlaying(songId);
} catch (e) {
  debugPrint('Scrobble failed: $e');
  // Play count lost!
}
```

**Problems**:
- ❌ Play counts lost on network failure
- ❌ No retry logic
- ❌ Doesn't survive app restart
- ❌ May block if network slow

### After (Queue-Based)

```dart
// Queue-based - never loses play counts
await _scrobbleQueue.queueNowPlaying(songId);
// Returns immediately, processes in background
```

**Benefits**:
- ✅ Play counts never lost
- ✅ Automatic retry with backoff
- ✅ Persists across app restarts
- ✅ Never blocks playback
- ✅ Works offline

## Future Enhancements

Potential improvements for future versions:

1. **Adaptive Retry**: Adjust retry timing based on network conditions
2. **Batch Submission**: Submit multiple scrobbles in single API call
3. **Priority Queue**: Prioritize recent plays over old queued items
4. **Queue Analytics**: Track queue size and retry patterns
5. **Configurable Limits**: User-configurable retry counts and age limits

## Related Documentation

- [Caching System](CACHING.md) - Persistence architecture
- [Error Handling](ERROR_HANDLING.md) - Error recovery strategies
- [Development Guide](DEVELOPMENT.md) - Architecture overview
- [Test Documentation](../test/README.md) - Test suite details
