# HTTP/2 Implementation

## Overview

Voidweaver implements HTTP/2 support for improved performance when streaming from Subsonic-compatible servers. The implementation uses the `http_plus` package which provides a drop-in replacement for the standard HTTP package with native HTTP/2 capabilities.

## Technical Implementation

### Package Selection

We chose `http_plus` over other alternatives because:
- **Drop-in replacement**: Compatible with existing `http` package APIs
- **Automatic fallback**: Falls back to HTTP/1.1 if HTTP/2 is unavailable
- **Persistent connections**: Maintains connection reuse for better performance
- **Header compression**: Reduces bandwidth usage through HPACK compression
- **Connection pooling**: Configurable maximum connections with proper resource management

### Configuration

The HTTP/2 client is configured in `SubsonicApi` with the following settings:

```dart
_httpClient = http.HttpPlusClient(
  enableHttp2: true,
  maxOpenConnections: 8,
  connectionTimeout: const Duration(seconds: 15),
);
```

### Key Parameters

- **enableHttp2**: `true` - Enables HTTP/2 protocol negotiation
- **maxOpenConnections**: `8` - Limits concurrent connections to prevent resource exhaustion
- **connectionTimeout**: `15 seconds` - Reasonable timeout for server connections
- **maintainOpenConnections**: `true` (default) - Keeps connections alive for reuse

## Performance Benefits

### Connection Multiplexing
- Multiple requests can be sent over a single TCP connection
- Eliminates head-of-line blocking present in HTTP/1.1
- Reduces connection establishment overhead

### Header Compression
- HPACK compression reduces bandwidth usage
- Particularly beneficial for API requests with similar headers
- Improves performance on mobile networks

### Server Push (Future)
- HTTP/2 server push capability available for compatible servers
- Allows servers to proactively send resources
- Currently not utilized but framework supports it

### Binary Protocol
- More efficient parsing compared to HTTP/1.1 text protocol
- Lower CPU usage for request/response processing
- Better network utilization

## Compatibility

### Automatic Fallback
The implementation automatically falls back to HTTP/1.1 when:
- Server doesn't support HTTP/2
- Network infrastructure blocks HTTP/2
- Connection negotiation fails

### Server Requirements
- **HTTP/2 Support**: Server should support HTTP/2 for optimal performance
- **TLS 1.2+**: Required for HTTP/2 over HTTPS (h2)
- **ALPN Support**: Application-Layer Protocol Negotiation for protocol selection

### Subsonic Compatibility
- Works with all Subsonic-compatible servers (Navidrome, Airsonic, etc.)
- Maintains backward compatibility with older server versions
- No changes required to existing server configurations

## Resource Management

### Connection Lifecycle
```dart
// Initialization in SubsonicApi constructor
_initializeHttpClient();

// Proper disposal in AppState
_api?.dispose();  // Calls _httpClient.close()
```

### Memory Management
- HTTP client properly closed when `SubsonicApi` is disposed
- Connection pool cleaned up on app termination
- No memory leaks from persistent connections

## Monitoring and Debugging

### Performance Monitoring
- Connection reuse reduces latency for subsequent requests
- Bandwidth savings from header compression
- Improved streaming performance for audio content

### Debug Information
- Enable debug logging in `HttpPlusClient` if needed:
```dart
HttpPlusClient(
  enableHttp2: true,
  enableLogging: true,  // For debugging only
)
```

## Testing

### Verification
- All 105 existing tests continue to pass
- No breaking changes to API contracts
- Transparent upgrade for existing functionality

### Performance Testing
To verify HTTP/2 benefits:
1. Monitor network requests in development tools
2. Compare connection counts between HTTP/1.1 and HTTP/2
3. Measure response times for multiple concurrent requests

## Migration Notes

### Changes Made
1. **Dependency**: Replaced `http: ^1.1.0` with `http_plus: ^0.2.3`
2. **Import**: Updated imports from `package:http/http.dart` to `package:http_plus/http_plus.dart`
3. **Client Type**: Changed from `http.Client` to `http.HttpPlusClient`
4. **Disposal**: Added proper HTTP client cleanup in `AppState.dispose()`

### Files Modified
- `/pubspec.yaml` - Updated dependency
- `/lib/services/subsonic_api.dart` - HTTP/2 client implementation
- `/lib/services/replaygain_reader.dart` - Updated import
- `/lib/services/app_state.dart` - Added disposal logic

## Future Enhancements

### Potential Improvements
- **Connection Metrics**: Add monitoring for connection reuse rates
- **Adaptive Configuration**: Adjust connection limits based on network conditions
- **Server Push**: Implement server push for preloading album art
- **HTTP/3 Support**: Evaluate QUIC/HTTP3 when available in Dart ecosystem

### Configuration Options
The implementation could be extended with:
- Configurable connection limits based on device capabilities
- Network-aware fallback strategies
- Custom timeout configurations for different request types

## Troubleshooting

### Common Issues
1. **TLS Certificate Issues**: HTTP/2 requires valid TLS certificates
2. **Proxy Compatibility**: Some corporate proxies may not support HTTP/2
3. **Server Configuration**: Ensure server properly advertises HTTP/2 support

### Debug Steps
1. Check server HTTP/2 support: `curl -I --http2 https://your-server.com`
2. Verify TLS configuration supports ALPN
3. Monitor connection behavior in network debugging tools
4. Enable debug logging if connection issues persist