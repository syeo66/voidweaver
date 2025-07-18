# Development Guide

## Development Commands

### Core Development
- `flutter run` - Run the app on connected device/emulator
- `flutter run -d chrome` - Run the app in web browser
- `flutter run -d <device_id>` - Run on specific device
- `flutter devices` - List available devices
- When starting the app, prefer the android emulator

### Code Quality
- `flutter analyze` - Static analysis (currently 0 issues)
- `flutter test` - Run test suite (49/49 passing)
- `flutter doctor` - Check Flutter installation and dependencies

### Building
- `flutter build apk` - Build Android APK
- `flutter build apk --release` - Build release APK
- `flutter build ios` - Build iOS app
- `flutter build web` - Build web app

## Architecture

Voidweaver uses a clean, optimized architecture with:

- **Provider** pattern for efficient state management with comprehensive loading states
- **Service layer** for API communication, audio playback, ReplayGain processing, and server scrobbling
- **Native audio service integration** for system-level media controls and background playback
- **Client-side metadata extraction** for ReplayGain data from audio files
- **Automatic server notifications** for played songs and listening statistics
- **Responsive UI** with Material Design, comprehensive settings management, and extensive loading state feedback
- **Background synchronization** for keeping data fresh with proper status indicators
- **Efficient HTTP range requests** for metadata extraction with minimal bandwidth usage
- **Performance-optimized widgets** with const constructors and minimal rebuilds
- **Advanced image caching system** with disk-based storage and intelligent placeholder handling
- **Comprehensive loading state management** with granular states for all operations and proper error handling
- **Advanced caching system** with multi-level caching, request deduplication, and intelligent invalidation
- **Production-ready logging** with proper error handling and debugging capabilities

## Testing

### Comprehensive Test Coverage

✅ **Current Status**: Zero analyzer warnings, optimized performance, comprehensive test coverage

```bash
flutter analyze          # Static analysis (currently 0 issues)
flutter test             # Run tests (49/49 passing)
flutter test --coverage  # Run tests with coverage report
```

**Test Coverage**: 49 comprehensive tests covering:
- Data model validation (Song, Album, Artist, SearchResult)
- Utility functions (time formatting, ReplayGain parsing, URL validation)
- Sleep timer functionality with comprehensive edge case testing
- API caching system with request deduplication and multi-level caching
- Widget instantiation and basic UI components
- Mock infrastructure for AudioPlayer plugin testing

### Recent Technical Improvements

- **Advanced caching system**: Implemented comprehensive multi-level caching with request deduplication
  - API response caching for albums, artists, search results with configurable TTL
  - Memory cache for instant access, persistent cache for offline capability
  - Request deduplication prevents duplicate network calls
  - Intelligent cache invalidation with pattern matching
  - Optimized image caching with size limits and fade animations
  - Added 7 comprehensive tests for caching functionality (49/49 total tests passing)
- **Testable architecture and comprehensive test coverage**: Fixed all failing tests and implemented robust testing infrastructure
  - Refactored AudioPlayerService to accept optional dependency injection for testing
  - Created comprehensive MockAudioPlayer with stream simulation for reliable testing
  - Fixed all plugin-related test failures that prevented CI/CD workflows
  - Achieved 100% test pass rate (49/49 tests) with comprehensive coverage
  - Added robust mock infrastructure for future audio functionality testing
  - Maintained backward compatibility while enabling reliable automated testing
- **Comprehensive loading states**: Implemented extensive loading state management across the entire application
  - Added granular loading states for server operations, audio playback, search, and artist browsing
  - Enhanced all screens with proper loading indicators and user feedback
  - Implemented context-safe async operations with proper error handling
  - Added pull-to-refresh functionality and retry mechanisms throughout the app
- **Native media controls**: Added comprehensive system-level media control integration with lock screen controls, notification panel controls, and external device support
- **Dark mode support**: Added comprehensive theme management with System/Light/Dark options
- **Comprehensive search functionality**: Added real-time search for artists, albums, and songs with categorized results
- **Next track preloading**: Implemented seamless playback transitions with automatic URL preloading
- **Interactive progress seeking**: Enhanced music player with tap-to-seek and drag-to-scrub functionality
- **Advanced image caching**: Implemented robust disk-based caching for all album art with automatic persistence
- **Secure credential storage**: Implemented encrypted storage with automatic migration from legacy SharedPreferences
- **Server notification implementation**: Added comprehensive scrobbling and now playing notifications
- Fixed 148 Flutter analyzer warnings for optimal performance
- Added const constructors throughout the app for better widget efficiency
- Removed dead code and unused imports for cleaner codebase
- Updated deprecated APIs for future compatibility
- Improved error handling with proper async context management
- Fixed cover art reloading issue when skipping tracks by implementing proper equality operators
- Optimized ReplayGain processing to prevent unnecessary UI rebuilds

## Performance Optimizations

- Const constructors minimize widget rebuilds
- Efficient Provider usage with specific notifiers
- HTTP range requests for metadata (minimal bandwidth)
- Proper resource disposal in all services
- Selective UI updates to prevent unnecessary rebuilds during playback state changes
- Stable ValueKey usage for consistent widget identity and caching
- Advanced image caching with automatic disk storage for album art
- Intelligent cache management with customizable expiration policies
- **Request deduplication** - Prevents duplicate API calls from running simultaneously
- **Comprehensive API response caching** - Cached albums, artists, search results with configurable TTL
- **Memory and persistent caching** - Multi-level caching for optimal performance and offline capability

## Error Handling

- Comprehensive try-catch blocks in all services
- User-friendly error messages displayed in UI
- Debug output with proper debugPrint() usage
- Graceful fallbacks for missing data
- UTF-8 encoding handled with proper byte decoding and malformed character support

## Development Patterns

- Follow existing code style and patterns
- Use Provider for state management
- Implement proper error boundaries
- Add const constructors for performance
- Use debugPrint() for debug output
- Handle async operations with proper mounted checks

## Audio Service Integration

- Audio service initializes automatically when server is configured in AppState
- VoidweaverAudioHandler manages communication between AudioPlayerService and system controls
- MediaItem updates occur automatically when tracks change
- Graceful fallback ensures app works without native controls if initialization fails
- Import conflicts resolved using namespace aliases (audio_player_service.dart as aps)

## Android Configuration

### Audio Service Setup
The app uses `audio_service` package for native media controls, requiring specific Android configuration:

#### MainActivity.kt Configuration
```kotlin
package com.example.voidweaver

import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity()
```

#### AndroidManifest.xml Permissions
```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
```

#### AndroidManifest.xml Service Configuration
```xml
<service android:name="com.ryanheise.audioservice.AudioService"
    android:foregroundServiceType="mediaPlayback"
    android:exported="true">
    <intent-filter>
        <action android:name="android.media.browse.MediaBrowserService" />
    </intent-filter>
</service>

<receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver"
    android:exported="true">
    <intent-filter>
        <action android:name="android.intent.action.MEDIA_BUTTON" />
    </intent-filter>
</receiver>
```

### Key Configuration Files
- `android/app/src/main/kotlin/com/example/voidweaver/MainActivity.kt` - AudioServiceActivity integration
- `android/app/src/main/AndroidManifest.xml` - Permissions and service declarations

## Important Implementation Details

### Authentication
- Uses Subsonic API token-based authentication with salt/token generation
- Credentials stored securely using flutter_secure_storage with device encryption
- Automatic migration from legacy SharedPreferences storage
- Automatic re-authentication on app startup with comprehensive error handling

### Data Flow
1. App initializes through AppState.initialize()
2. Server credentials loaded from secure storage with automatic SharedPreferences migration
3. SubsonicApi configured for authenticated requests
4. AudioPlayerService created with ReplayGain integration
5. Native audio service initialized with VoidweaverAudioHandler for system media controls
6. Background sync timer started for album updates
7. UI reflects state changes through Provider notifications

## Requirements

- **Network Access**: Required for streaming music from your server and metadata extraction
- **Audio Playback**: Uses device audio capabilities with volume control for ReplayGain
- **Secure Storage**: Uses device-level encryption for login credentials and local storage for ReplayGain settings
- **HTTP Range Requests**: Server must support partial content requests for metadata extraction