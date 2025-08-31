# Development Guide

## Development Commands

### Makefile Targets (Preferred)
The project includes a Makefile for streamlined development workflows:
- `make run` - Run app on connected device/emulator (includes setup)
- `make run-web` - Run in web browser
- `make test` - Run all tests with setup validation
- `make analyze` - Static analysis (currently 0 issues)
- `make format` - Format Dart code in lib/ and test/
- `make build-release` - Full validation pipeline (format, analyze, test) + release APK
- `make clean` - Clean build artifacts
- `make doctor` - Check Flutter installation
- `make devices` - List available devices
- `make setup` - Ensure Flutter is installed and get dependencies
- `make help` - Show all available targets

### Direct Flutter Commands
- `flutter run` - Run the app on connected device/emulator
- `flutter run -d chrome` - Run the app in web browser
- `flutter run -d <device_id>` - Run on specific device
- `flutter devices` - List available devices
- When starting the app, prefer the android emulator

### Code Quality
- `flutter analyze` - Static analysis (currently 0 issues)
- `flutter test` - Run test suite (142+ passing with comprehensive just_audio mocks and Bluetooth controls validation)
- `flutter pub deps` - Check dependency graph including HTTP/2 support
- `flutter test test/utils/validators_test.dart` - Run input validation tests specifically
- `flutter test test/widgets/error_boundary_test.dart` - Run error boundary tests specifically
- `flutter test test/services/error_handler_test.dart` - Run error handler tests specifically
- `flutter doctor` - Check Flutter installation and dependencies

### Building
- `flutter build apk` - Build Android APK
- `flutter build apk --release` - Build release APK
- `flutter build ios` - Build iOS app
- `flutter build web` - Build web app

## Architecture

Voidweaver uses a clean, optimized architecture with:

- **Provider** pattern for efficient state management with comprehensive loading states
- **Service layer** for HTTP/2-enabled API communication with mandatory HTTPS enforcement, just_audio-based playback, ReplayGain processing, and server scrobbling
- **Native audio service integration** for system-level media controls and background playback
- **Client-side metadata extraction** for ReplayGain data from audio files
- **Automatic server notifications** for played songs and listening statistics
- **Responsive UI** with Material Design, comprehensive landscape support, settings management, and extensive loading state feedback
- **Background synchronization** for keeping data fresh with proper status indicators
- **HTTP/2 protocol support** with connection reuse, header compression, and automatic HTTP/1.1 fallback
- **Efficient HTTP range requests** for metadata extraction with minimal bandwidth usage
- **Performance-optimized widgets** with const constructors and minimal rebuilds
- **Advanced image caching system** with disk-based storage and intelligent placeholder handling
- **Comprehensive loading state management** with granular states for all operations and proper error handling
- **Advanced caching system** with multi-level caching, request deduplication, and intelligent invalidation
- **Production-ready logging** with proper error handling and debugging capabilities
- **Error boundary system** with global error handling, widget-level error boundaries, and user-friendly error recovery

## Testing

### Comprehensive Test Coverage

✅ **Current Status**: Zero analyzer warnings, optimized performance, comprehensive test coverage

```bash
flutter analyze          # Static analysis (currently 0 issues)
flutter test             # Run tests (142/142 passing)
flutter test --coverage  # Run tests with coverage report
```

**Test Coverage**: 142 comprehensive tests covering:
- Data model validation (Song, Album, Artist, SearchResult)
- Utility functions (time formatting, ReplayGain parsing, URL validation)
- Sleep timer functionality with comprehensive edge case testing
- API caching system with request deduplication and multi-level caching
- Input validation and sanitization (37 comprehensive tests covering security scenarios, edge cases, and user input handling)
- Error boundary system (15 tests covering widget error handling, global error management, and user recovery flows)
- Widget instantiation and basic UI components
- Mock infrastructure for AudioPlayer plugin testing
- HTTPS security enforcement (5 comprehensive tests covering URL validation, API rejection of HTTP connections, and proper error handling)

### Recent Technical Improvements

- **HTTPS enforcement**: Implemented mandatory encrypted connections for enhanced security
  - Multi-layer validation: validators, SubsonicApi constructor, and UI feedback
  - All HTTP connections rejected with clear error messages
  - Updated login screen with HTTPS requirement indicators and lock icon
  - Comprehensive test coverage with 5 new tests covering URL validation and API rejection
  - Defense-in-depth approach protects credentials and music data in transit
  - Clear user guidance about HTTPS requirement in login form

- **Comprehensive input validation**: Implemented robust input validation and sanitization system
  - Added comprehensive validation for login form fields (server URL, username, password)
  - Enhanced settings validation for ReplayGain parameters with range checking
  - Input sanitization removes control characters and handles malformed data
  - 37 comprehensive test cases covering all validation scenarios, edge cases, and security concerns
  - Protection against crashes from invalid user inputs
  - Clear, actionable error messages for better user experience

- **Error boundary system**: Implemented comprehensive error handling to prevent app crashes
  - Global error handler catches uncaught exceptions and async errors
  - Widget-level error boundaries protect individual UI components
  - User-friendly error displays with retry mechanisms and helpful messages
  - Error reporting infrastructure with console logging and memory storage for debugging
  - Extension methods for easy error boundary wrapping (.withErrorBoundary())
  - 15 comprehensive tests covering all error handling scenarios and user recovery flows
  - Graceful degradation ensures the app continues functioning even when components fail

- **Advanced caching system**: Implemented comprehensive multi-level caching with request deduplication
  - API response caching for albums, artists, search results with configurable TTL
  - Memory cache for instant access, persistent cache for offline capability
  - Request deduplication prevents duplicate network calls
  - Intelligent cache invalidation with pattern matching
  - Optimized image caching with size limits and fade animations
  - Added 7 comprehensive tests for caching functionality (105/105 total tests passing)
- **Testable architecture and comprehensive test coverage**: Fixed all failing tests and implemented robust testing infrastructure
  - Refactored AudioPlayerService to accept optional dependency injection for testing
  - Created comprehensive MockAudioPlayer using just_audio API with broadcast streams for reliable testing
  - Fixed all plugin-related test failures that prevented CI/CD workflows
  - Achieved 100% test pass rate (105/105 tests) with comprehensive coverage
  - Added robust mock infrastructure for future audio functionality testing
  - Maintained backward compatibility while enabling reliable automated testing
- **Comprehensive loading states**: Implemented extensive loading state management across the entire application
  - Added granular loading states for server operations, audio playback, search, and artist browsing
  - Enhanced all screens with proper loading indicators and user feedback
  - Implemented context-safe async operations with proper error handling
  - Added pull-to-refresh functionality and retry mechanisms throughout the app
- **Native media controls**: Added comprehensive system-level media control integration with lock screen controls, notification panel controls, and external device support
- **Dark mode support**: Added comprehensive theme management with System/Light/Dark options
- **Comprehensive landscape support**: Implemented responsive layouts for optimal mobile experience
  - Login screen with side-by-side layout (branding + form) in landscape mode
  - Now playing screen with horizontal album art and song info layout
  - Player controls with compact landscape layout for efficient space usage
  - Album list with responsive 3-column grid view in landscape mode
  - Playlist view with compact items in landscape for space efficiency
  - Orientation detection using MediaQuery for seamless layout switching
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
- **Comprehensive skip protection**: Implemented advanced atomic skip operations with multi-layer race condition prevention
- Optimized ReplayGain processing to prevent unnecessary UI rebuilds

## Performance Optimizations

- **HTTP/2 networking** with connection pooling (max 8 connections), persistent connections, and header compression
- **Automatic protocol negotiation** with fallback to HTTP/1.1 for compatibility
- Const constructors minimize widget rebuilds
- Efficient Provider usage with specific notifiers
- HTTP range requests for metadata (minimal bandwidth)
- Proper resource disposal in all services including HTTP client cleanup
- Selective UI updates to prevent unnecessary rebuilds during playback state changes
- Service-level debouncing architecture prevents conflicts between UI controls and system media controls
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
- Input validation prevents crashes from malformed user data
- Sanitization of all user inputs to remove control characters and prevent security issues

## Development Patterns

- Follow existing code style and patterns
- Use Provider for state management
- Implement proper error boundaries
- Add const constructors for performance
- Use debugPrint() for debug output
- Handle async operations with proper mounted checks

## Audio Service Integration

- **just_audio backend**: Migrated from audioplayers to just_audio for improved ExoPlayer integration and enhanced Bluetooth support
- **Dual State Architecture**: VoidweaverAudioHandler uses both AudioPlayerService state updates and direct just_audio PlayerState listening for reliable media controls
- **Skip State Masking**: During skip operations, masks transient paused states from audio_service to prevent Bluetooth control confusion
- **Audio Focus Optimization**: Removes interfering audio focus requests during skip operations to improve reliability
- Audio service initializes automatically when server is configured in AppState
- VoidweaverAudioHandler manages communication between AudioPlayerService and system controls using audio_service
- MediaItem updates occur automatically when tracks change
- PlayerState monitoring: Uses just_audio's playerStateStream for real-time state synchronization
- Graceful fallback ensures app works without native controls if initialization fails
- Import conflicts resolved using namespace aliases (audio_player_service.dart as aps)
- **Bluetooth Controls**: Skip operations now work reliably; minor play-after-pause issue remains (see [BLUETOOTH_CONTROLS.md](BLUETOOTH_CONTROLS.md) and TODO.md)

## Advanced Skip Protection Architecture

### Problem Resolution
Completely resolved double-skip race conditions that occurred when multiple skip sources (manual controls, song completion events) executed simultaneously, especially on fast hardware.

### Comprehensive Solution Architecture

**Multi-Layer Protection System:**

1. **Operation-Level Locking**
   - `_skipOperationInProgress` flag prevents concurrent skip operations from any source
   - Immediate playback stop during manual skips prevents completion events
   - Global protection across UI controls, native controls, and auto-advance

2. **Dual Index Tracking**
   - `_currentIndex`: Working index during transitions
   - `_confirmedIndex`: Last confirmed playing track position
   - Auto-advance uses confirmed index to prevent race conditions

3. **Completion Event Protection**
   - `_lastCompletedSongId` prevents duplicate completion handling from just_audio events
   - `_lastManualCompletedSongId` prevents duplicate manual completion handling
   - Song completion events blocked during active skip operations
   - **Manual completion fallback** with position-based detection (500ms tolerance) handles cases where just_audio completion events fail due to network buffering or codec timing issues
   - Proper cleanup of duplicate event listeners

4. **Comprehensive Logging**
   - 20-entry timestamped change log (`_indexChangeLog`)
   - Detailed operation source tracking for debugging
   - Index change validation with jump detection
   - Manual completion fallback logging with position and duration details

5. **Atomic Operations**
   - Immediate audio stop before track changes
   - Sequential operation completion with proper state cleanup
   - Zone-safe error handling and resource management

**Protected Sources:**
- UI skip buttons and player controls
- Native media controls (headphones, lock screen, notifications)
- Automatic song completion events
- External device controls (Bluetooth, car systems)

This architecture ensures reliable single-track advancement regardless of timing, hardware speed, or operation source, completely eliminating double-skip behavior under all conditions.

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
- **HTTPS Enforcement**: Mandatory encrypted connections to protect credentials and music data in transit
- Uses Subsonic API token-based authentication with salt/token generation
- Credentials stored securely using flutter_secure_storage with device encryption
- Automatic migration from legacy SharedPreferences storage
- Automatic re-authentication on app startup with comprehensive error handling
- Multi-layer HTTPS validation (validators, API constructor, UI feedback)

### Data Flow
1. App initializes through AppState.initialize()
2. Server credentials loaded from secure storage with automatic SharedPreferences migration
3. SubsonicApi configured with HTTP/2 client for authenticated requests
4. AudioPlayerService created with ReplayGain integration
5. Native audio service initialized with VoidweaverAudioHandler for system media controls
6. Background sync timer started for album updates
7. UI reflects state changes through Provider notifications

## Requirements

- **Network Access**: Required for streaming music from your server and metadata extraction
- **Audio Playback**: Uses device audio capabilities with volume control for ReplayGain
- **Secure Storage**: Uses device-level encryption for login credentials and local storage for ReplayGain settings
- **HTTP Range Requests**: Server must support partial content requests for metadata extraction
- **HTTP/2 Support**: Automatically negotiated with fallback to HTTP/1.1 for older servers