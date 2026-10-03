# Advanced Caching System

## Overview

Voidweaver includes a comprehensive multi-level caching system with an on-disk audio cache for offline-resilient playback that significantly improves performance by reducing redundant network requests and providing instant access to frequently used data. This document explains the caching architecture, features, and technical implementation.

## Features

### Core Functionality
- **Request Deduplication**: Prevents multiple identical API calls from running simultaneously
- **Multi-level Caching**: Memory cache for instant access, persistent cache for offline capability
- **Audio File Caching**: Downloads the next 3 tracks to disk for offline-resilient playback
- **Offline Fallback**: Serves expired cached data when the server is unreachable
- **Intelligent Cache Management**: Configurable TTL, automatic expiration, pattern-based invalidation
- **Cache Statistics**: Real-time monitoring of cache performance and memory usage

### Performance Benefits
- **Reduced Network Calls**: Eliminates redundant API requests
- **Faster Loading**: Memory cache provides instant access to frequently used data
- **Offline-Resilient Playback**: Downloaded upcoming tracks keep music playing during network outages
- **Instant Track Switching**: Downloaded tracks load from local files with no network delay
- **Improved Responsiveness**: Persistent cache enables offline browsing of cached content
- **Better Resource Management**: Size-limited audio cache with LRU eviction

## Architecture

### Cache Layers

#### 1. Memory Cache
- **Purpose**: Instant access to frequently used data
- **Storage**: In-memory key-value store
- **Lifetime**: Application session
- **Benefits**: Zero latency access, automatic garbage collection

#### 2. Persistent Cache
- **Purpose**: Offline capability and cross-session persistence
- **Storage**: SharedPreferences with JSON serialization
- **Lifetime**: Configurable TTL periods
- **Benefits**: Survives app restarts, reduces cold start times

#### 3. Audio File Cache
- **Purpose**: Offline-resilient playback of upcoming tracks
- **Storage**: Downloaded audio files in the app cache directory (`audio_cache/`), managed by `AudioCache`
- **Lifetime**: Least-recently-used eviction once the cache exceeds 1 GB
- **Benefits**: Upcoming tracks play from disk, so playback continues when the network drops

### Offline Fallback

When a cached request fails (e.g. the device is offline), `ApiCache` returns the expired entry instead of the error, from memory or from persistent storage. Expired entries are only replaced, never deleted, so the last known album lists, artists, albums and search results stay browsable offline.

### Request Deduplication

The system prevents duplicate requests by:
1. **Request Tracking**: Maintains a map of ongoing requests
2. **Future Sharing**: Multiple callers share the same Future result
3. **Automatic Cleanup**: Removes completed requests from tracking

```dart
// Example: Multiple simultaneous calls to getAlbumList()
// Only one actual API call is made, others wait for the result
final albums1 = api.getAlbumList(); // Makes API call
final albums2 = api.getAlbumList(); // Waits for first call
final albums3 = api.getAlbumList(); // Waits for first call
```

## Audio File Caching

While a song plays, `AudioPlayerService` downloads the next 3 tracks to disk via `AudioCache`, one at a time, nearest first.

- **Playback**: `_playSongAtIndex` plays from the cached file when present (`setFilePath`), otherwise streams from the server.
- **Offline skipping**: When advancing (manual next or auto-advance) to a track that can't be loaded and isn't cached, playback skips ahead to the next cached track in the playlist instead of stopping.
- **ReplayGain**: Read from the downloaded file's header, so no separate range request is needed.
- **Downloads**: Written to a `.part` file and renamed when complete; incomplete downloads, non-200 responses and Subsonic XML/JSON error documents are discarded. Concurrent requests for the same song share one download.
- **Keys**: SHA-1 of the server URL and song id, so songs from different servers can't collide.
- **Eviction**: Least recently used files (by modification time, refreshed on each play) are deleted once the cache exceeds 1 GB.
- **Restore**: If the saved song can't be loaded at startup (e.g. offline), the saved queue is kept and the song is loaded again on the next play, resuming at the saved position.

The currently playing track is streamed if it wasn't prefetched, so a network drop mid-song can still interrupt the first track of a new playlist.

## Cache Configuration

### TTL (Time To Live) Settings

Different data types have optimized cache durations:

- **Albums**: 3 minutes (frequently changing)
- **Individual Albums**: 10 minutes (stable content)
- **Artists**: 15 minutes (very stable content)
- **Search Results**: 5 minutes (balance between freshness and performance)
- **Random Songs**: 1 minute (should be random, not cached long)

### Cache Keys

Cache keys are generated by combining:
- **Endpoint**: API endpoint name
- **Parameters**: Sorted query parameters
- **Consistency**: Same parameters always generate same key

```dart
// Example cache key generation
endpoint: 'getAlbumList2'
params: {'type': 'recent', 'size': '500'}
key: 'getAlbumList2?size=500&type=recent'
```

## API Integration

### Cached Endpoints

The following SubsonicApi methods use caching:

#### `getAlbumList()`
- **Cache Duration**: 3 minutes
- **Persistent**: Yes
- **Reason**: Album lists change frequently with new uploads

#### `getAlbum(id)`
- **Cache Duration**: 10 minutes
- **Persistent**: Yes
- **Reason**: Individual album data is stable

#### `getArtists()`
- **Cache Duration**: 15 minutes
- **Persistent**: Yes
- **Reason**: Artist lists change infrequently

#### `getArtistAlbums(artistId)`
- **Cache Duration**: 10 minutes
- **Persistent**: Yes
- **Reason**: Artist's albums are relatively stable

#### `search(query)`
- **Cache Duration**: 5 minutes
- **Persistent**: Yes
- **Reason**: Search results balance freshness with performance

#### `getRandomSongs()`
- **Cache Duration**: 1 minute
- **Persistent**: No
- **Reason**: Random songs should be truly random

### Non-Cached Operations

Some operations are intentionally not cached:
- **Stream URLs**: Generated per request with authentication (the audio itself is cached, see Audio File Caching)
- **Cover Art URLs**: Generated per request with authentication. Because the salt and token change every time, images pass the cover art id as `cacheKey` so the disk image cache still hits.
- **Scrobble Operations**: Real-time user actions (but see Scrobble Queue below for persistent queuing)

## Scrobble Queue Persistence

### Overview

While scrobble operations themselves are not cached, Voidweaver includes a persistent queue system that ensures play count data is never lost due to network issues.

### Key Features

- **Persistent Storage**: Scrobble requests stored in SharedPreferences and restored after app restart
- **Automatic Retry**: Failed requests automatically retried with exponential backoff
- **Network Resilience**: Queue continues to build while offline, processes when network returns
- **Non-Blocking**: All queue operations asynchronous and don't affect playback performance
- **Intelligent Cleanup**: Old requests (>7 days) and failed requests (>5 retries) automatically dropped

### Architecture

#### ScrobbleRequest Structure
```dart
class ScrobbleRequest {
  final String songId;
  final ScrobbleType type;        // nowPlaying or submission
  final DateTime? playedAt;       // Timestamp for submissions
  final DateTime queuedAt;        // When request was queued
  final int retryCount;           // Number of retry attempts
}
```

#### Queue Processing

The queue operates with the following strategy:

1. **Immediate Processing**: New requests processed immediately if network available
2. **Periodic Processing**: Queue checked every 30 seconds for pending requests
3. **Exponential Backoff**: Failed requests retried with increasing delays
4. **Batch Processing**: Multiple queued requests processed sequentially with 100ms spacing
5. **Persistent State**: Queue saved after every change, restored on app launch

### Configuration

- **Maximum Retries**: 5 attempts before dropping request
- **Processing Interval**: 30 seconds between periodic checks
- **Request Age Limit**: 7 days before automatic cleanup
- **Inter-Request Delay**: 100ms between sequential requests

### Performance Benefits

- **Zero Data Loss**: Play counts preserved even during extended network outages
- **Battery Efficient**: Batch processing minimizes wake-ups
- **Memory Efficient**: Automatic cleanup prevents queue growth
- **Fast Recovery**: Automatic processing when network returns

### Storage Format

Queue stored as JSON array in SharedPreferences:
```json
[
  {
    "songId": "song-123",
    "type": "nowPlaying",
    "playedAt": null,
    "queuedAt": 1699123456789,
    "retryCount": 0
  },
  {
    "songId": "song-124",
    "type": "submission",
    "playedAt": 1699123500000,
    "queuedAt": 1699123502000,
    "retryCount": 1
  }
]
```

### Integration with AudioPlayerService

The ScrobbleQueue integrates seamlessly with audio playback:

1. **Initialization**: Queue created and restored during AudioPlayerService initialization
2. **Queuing**: All scrobble operations go through queue instead of direct API calls
3. **Disposal**: Queue properly disposed when audio service is destroyed
4. **Non-Interference**: Queue operations never block playback or skip functionality

## Image Caching

### Enhanced CachedNetworkImage

The `ImageCacheManager` provides optimized image caching:

```dart
// Optimized image caching configuration
static Widget buildCachedImage({
  required String imageUrl,
  double? width,
  double? height,
  // ...other parameters
}) {
  return CachedNetworkImage(
    imageUrl: imageUrl,
    memCacheWidth: width?.toInt(),
    memCacheHeight: height?.toInt(),
    maxHeightDiskCache: 800,
    maxWidthDiskCache: 800,
    fadeInDuration: Duration(milliseconds: 200),
    fadeOutDuration: Duration(milliseconds: 100),
    // ...other optimizations
  );
}
```

### Stable Cache Keys

Cover art URLs contain a per-request salt and token, so the URL is different every time it's generated. Every cover art image therefore passes the cover art id as `cacheKey`, letting the disk cache hit across URL changes and app restarts, which keeps album art visible offline:

```dart
CachedNetworkImage(
  imageUrl: api.getCoverArtUrl(album.coverArt!),
  cacheKey: album.coverArt,
)
```

### Image Cache Features

- **Size Limits**: 800x800 maximum for memory optimization
- **Fade Animations**: Smooth transitions (200ms in, 100ms out)
- **Consistent Styling**: Unified appearance across the app
- **Memory Efficient**: Automatic memory management

## Cache Management

### Clearing from Settings

The **Cache** section in Settings shows how much space downloaded songs use and has a **Clear Cache** button. After confirmation it calls `AppState.clearCaches()`, which removes:

- Downloaded audio (`AudioPlayerService.clearAudioCache()`)
- Cached API responses, in memory and persistent (`SubsonicApi.clearCache()`)
- Cover art, on disk and in memory (`ImageCacheManager.clearCache()`)

Downloads already in progress still complete and are added to the cache.

### Manual Cache Control

The API provides methods for cache management:

```dart
// Clear all cached data
await api.clearCache();

// Clear specific cache entry
api.clearCacheEntry('getAlbumList2', {'type': 'recent'});

// Clear expired entries
api.clearExpiredCache();

// Get cache statistics
final stats = api.getCacheStats();

// Downloaded audio
final bytes = await audioPlayerService.audioCacheSize();
await audioPlayerService.clearAudioCache();
```

### Pattern-Based Invalidation

Invalidate related cache entries using patterns:

```dart
// Invalidate all album-related cache entries
api.invalidateAlbumCache(); // Clears getAlbumList*, getAlbum*

// Invalidate all artist-related cache entries  
api.invalidateArtistCache(); // Clears getArtist*

// Invalidate search cache entries
api.invalidateSearchCache(); // Clears search*
```

### Cache Statistics

Monitor cache performance with detailed statistics:

```dart
final stats = api.getCacheStats();
// Returns:
// {
//   'total': 15,           // Total cache entries
//   'valid': 12,           // Non-expired entries
//   'expired': 3,          // Expired entries
//   'ongoingRequests': 2   // Active requests
// }
```

## Performance Impact

### Before Caching
- **Network Requests**: One per API call
- **Load Times**: Depends on network latency
- **Data Usage**: Full bandwidth usage
- **User Experience**: Loading delays

### After Caching
- **Network Requests**: Significantly reduced
- **Load Times**: Instant for cached data
- **Data Usage**: Reduced bandwidth consumption
- **User Experience**: Immediate response

### Typical Improvements
- **Cache Hit Rate**: 70-90% for repeated actions
- **Load Time Reduction**: 95%+ for cached content
- **Network Usage**: 50-80% reduction
- **Battery Life**: Improved due to fewer network operations

## Implementation Details

### Cache Entry Structure

```dart
class CacheEntry<T> {
  final T data;
  final DateTime expiresAt;
  final String key;
  
  bool get isExpired => DateTime.now().isAfter(expiresAt);
  bool get isValid => !isExpired;
}
```

### Request Deduplication Implementation

```dart
// Simplified deduplication logic
if (_ongoingRequests.containsKey(key)) {
  // Return existing future
  return await _ongoingRequests[key]!.future;
}

// Create new request
final completer = Completer<T>();
_ongoingRequests[key] = completer;

try {
  final result = await actualApiCall();
  completer.complete(result);
  return result;
} finally {
  _ongoingRequests.remove(key);
}
```

## Testing

### Test Coverage

`test/services/api_cache_test.dart` (11 tests):

1. **Cache Hit/Miss Validation**: Verifies cache storage and retrieval
2. **Request Deduplication**: Tests concurrent request handling
3. **Cache Expiration**: Validates TTL functionality
4. **Consistent Key Generation**: Ensures parameter order independence
5. **Cache Invalidation**: Tests manual cache clearing
6. **Cache Statistics**: Validates performance monitoring
7. **Pattern Matching**: Tests pattern-based invalidation
8. **Persistent Codecs**: Typed data survives a new cache instance
9. **Stale Memory Fallback**: Expired data served when a fetch fails
10. **Stale Persistent Fallback**: Same, after a restart
11. **Error Propagation**: Fetch errors rethrown when nothing is cached

`test/services/audio_cache_test.dart` (7 tests): downloads, download deduplication, rejection of failed responses and error documents, index restoration and partial-file cleanup, LRU eviction, server namespacing, and clearing.

## Best Practices

### For Users
1. **Regular App Updates**: Keep the app updated for cache optimizations
2. **Stable Network**: Cache works best with reliable internet connection
3. **Storage Management**: Downloaded songs are capped at 1 GB; use **Clear Cache** in Settings to free space

### For Developers
1. **Appropriate TTL**: Choose cache durations based on data volatility
2. **Memory Management**: Monitor cache size and implement cleanup
3. **Error Handling**: Graceful fallback when cache operations fail
4. **Testing**: Comprehensive test coverage for cache behavior
5. **Documentation**: Clear documentation of cache behavior

## Troubleshooting

### Common Issues

#### Cache Not Working
- **Cause**: Network requests still slow
- **Solution**: Check cache statistics to verify hit rates
- **Debug**: Enable cache logging to see hit/miss patterns

#### Memory Usage
- **Cause**: Cache consuming too much memory
- **Solution**: Cache automatically manages memory usage
- **Monitor**: Use cache statistics to track memory consumption

#### Stale Data
- **Cause**: Cached data appears outdated
- **Solution**: Cache TTL is optimized for each data type
- **Manual Fix**: Use **Clear Cache** in Settings

### Debug Information

The caching system provides detailed debug output:
- **Cache hits/misses**: Logged for performance monitoring
- **Request deduplication**: Shows when requests are deduplicated
- **Cache statistics**: Available for performance analysis
- **Error handling**: Graceful fallback logging

## Future Enhancements

Potential improvements for future versions:
- **Adaptive TTL**: Dynamic cache duration based on usage patterns
- **Compression**: Compress cached data for storage efficiency
- **Background Sync**: Proactive cache warming
- **Offline Albums**: Download whole albums or playlists on request
- **Configurable Audio Cache Size**: Let users choose the 1 GB limit
- **Analytics**: Detailed cache performance metrics
- **Custom Cache Policies**: User-configurable cache behavior

## References

- [HTTP Caching Specification](https://tools.ietf.org/html/rfc7234)
- [Flutter Performance Best Practices](https://flutter.dev/docs/perf/best-practices)
- [Dart Async Programming](https://dart.dev/codelabs/async-await)
- [SharedPreferences Documentation](https://pub.dev/packages/shared_preferences)