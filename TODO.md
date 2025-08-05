# Voidweaver TODO

## 🚨 Critical Issues (Fix First)
**All critical issues have been resolved! ✅**

## 🔧 Core Functionality Gaps
- [x] **Fix bluetooth controls** - ✅ **FULLY FIXED** - Implemented comprehensive audio focus handling improvements:
  - [x] **Skip commands pause instead of advancing** - ✅ **FIXED** - Skip operations now work reliably with state masking during transitions
  - [x] **Play command requires double-press after pause** - ✅ **FIXED** - Implemented delayed audio focus requests and improved focus change handling to prevent conflicts
  - [x] **State synchronization issues** - ✅ **FIXED** - Implemented dual state architecture with direct just_audio PlayerState listening
  - [x] **Skip operation race conditions** - ✅ **FIXED** - Skip protection preserved while allowing proper state updates to audio_service
  
### Technical Fixes Implemented:
  - [x] **Skip state masking** - During skip operations, mask transient paused states from audio_service
  - [x] **Dual state listening** - VoidweaverAudioHandler listens directly to just_audio PlayerState for real-time updates
  - [x] **Audio focus optimization** - Removed audio focus requests during skip operations
  - [x] **Processing state masking** - Show consistent ready state during skip transitions
  - [x] **Delayed audio focus requests** - Request audio focus with 100ms delay after play to prevent immediate conflicts
  - [x] **Focus state tracking** - Track audio focus state to avoid unnecessary requests
  - [x] **Grace period for focus changes** - Android-side grace period (300ms) to ignore focus changes immediately after requests

## 🎨 UI/UX Improvements

### Visual Enhancements
- [ ] **Album art animations** - Smooth transitions and effects
- [x] **Organize search results in tabs** - ✅ Implemented tabbed search with Artists, Albums, Songs tabs and result counts

### Mobile Experience
- [x] **Landscape support** - ✅ Implemented responsive layouts for login, home screen, player controls, and album grids with landscape-optimized layouts

## ⚡ Performance & Architecture

### Code Quality
- [x] **Input validation** - ✅ Implemented comprehensive validation for login fields and settings with robust error handling, input sanitization, and 37 comprehensive test cases
- [x] **Error boundaries** - ✅ Implemented comprehensive error boundary system with global error handler, ErrorBoundary widgets, and error reporting infrastructure throughout the app
- [x] **Dependency updates** - ✅ Updated all dependencies to latest stable versions (July 2025), including flutter_lints 6.0.0, build tools, and security packages

### Performance Optimization
- [x] **HTTP/2 support** - ✅ Implemented HTTP/2 client with connection reuse, header compression, and automatic fallback to HTTP/1.1
- [x] **Request deduplication** - ✅ Implemented comprehensive request deduplication system
- [x] **API response caching** - ✅ Added multi-level caching with configurable TTL for albums, artists, and search results
- [ ] **Background sync optimization** - Smart sync based on usage patterns

### State Management
- [x] **Optimize Provider usage** - ✅ Implemented Selector patterns in PlayerControls to reduce rebuilds
- [x] **Memory leak prevention** - ✅ Comprehensive disposal patterns implemented across all services and widgets with 8 comprehensive tests covering AudioPlayerService, AppState, SubsonicApi, timers, streams, and resource cleanup
- [ ] **Local database** - Replace SharedPreferences with SQLite for complex data

## 🔒 Security & Reliability

### Security Improvements
- [x] **HTTPS enforcement** - ✅ Implemented mandatory HTTPS for all server connections with comprehensive validation in validators, SubsonicApi, and UI feedback
- [ ] **Certificate validation** - Proper handling of self-signed certificates
- [ ] **Credential validation** - Better login validation and feedback

### Error Handling
- [x] **Network timeout handling** - ✅ **FULLY IMPLEMENTED** - Comprehensive timeout and retry system with:
  - [x] **Configurable timeout types** - Separate timeouts for connection, request, metadata, and streaming operations
  - [x] **Exponential backoff retry logic** - Smart retry with jitter and configurable maximum attempts
  - [x] **Connection presets** - Fast, Default, and Slow presets optimized for different network conditions
  - [x] **User-friendly error messages** - Intelligent error categorization with specific troubleshooting suggestions
  - [x] **Advanced settings UI** - Fine-grained timeout configuration with validation
  - [x] **Comprehensive test coverage** - 19 tests covering all timeout scenarios and error handling
- [ ] **Offline mode** - Graceful handling when server unavailable
- [ ] **Structured logging** - Implement proper logging system
- [ ] **Crash reporting** - Add crash analytics for production

## 🧪 Testing & Quality

### Test Coverage
- [x] **Unit tests** - ✅ Comprehensive test suite (142+ passing) covering data models, utilities, sleep timer, caching functionality, input validation, Bluetooth controls, and network timeout handling
- [x] **Mock infrastructure** - ✅ Robust AudioPlayer mocking system for reliable testing
- [x] **Testable architecture** - ✅ Refactored AudioPlayerService with dependency injection
- [x] **Caching system tests** - ✅ Added 7 comprehensive tests for API cache, request deduplication, and cache invalidation
- [x] **Input validation tests** - ✅ Added 37 comprehensive tests covering all validation scenarios, edge cases, and security concerns
- [x] **Memory leak prevention tests** - ✅ Added 8 comprehensive tests covering service disposal, timer cleanup, stream subscription management, and resource safety
- [x] **Bluetooth controls tests** - ✅ Added 5 comprehensive tests covering audio focus management, delayed requests, state tracking, and conflict prevention
- [x] **Network timeout handling tests** - ✅ Added 19 comprehensive tests covering timeout configuration, retry logic, exponential backoff, error categorization, settings integration, and user-friendly error message generation
- [x] **Dependency compatibility testing** - ✅ All tests validated after major dependency updates to ensure no regressions
- [ ] **Integration tests** - Test complete user workflows
- [ ] **Audio playback tests** - Test core playback functionality beyond mocking
- [ ] **ReplayGain tests** - Test complex volume calculation logic

## 🎵 Advanced Features (Future)

### Audio Features
- [x] **Sleep timer** - ✅ Implemented auto-pause functionality with preset durations, visual indicators, and timer management
- [ ] **Equalizer** - Add audio EQ controls
- [ ] **Crossfade/gapless playback** - Smooth track transitions
- [ ] **Audio visualizer** - Visual representation of audio
- [ ] **Volume controls** - In-app volume slider

### Extended Features
- [ ] **Offline caching** - Download for offline listening

## 🌐 Platform Support

### Mobile Platforms
- [ ] **Battery optimization** - Implement power management

---

## Priority Legend
- 🚨 **Critical** - Fix immediately (broken functionality)
- 🔧 **High** - Essential features missing
- 🎨 **Medium** - User experience improvements
- ⚡ **Medium** - Technical debt and performance
- 🔒 **Medium** - Security and reliability
- 🧪 **Medium** - Testing and maintenance
- 🎵 **Low** - Nice-to-have features
- 🌐 **Low** - Platform-specific enhancements
