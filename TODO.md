# Voidweaver TODO

## 🚨 Critical Issues (Fix First)

## 🔧 Core Functionality Gaps
- [x] **Fix bluetooth controls** - ✅ **MOSTLY FIXED** - Implemented skip state masking and audio focus improvements:
  - [x] **Skip commands pause instead of advancing** - ✅ **FIXED** - Skip operations now work reliably with state masking during transitions
  - [ ] **Play command requires double-press after pause** - ⚠️ After pausing via Bluetooth, play command requires pressing twice to resume playback
  - [x] **State synchronization issues** - ✅ **FIXED** - Implemented dual state architecture with direct just_audio PlayerState listening
  - [x] **Skip operation race conditions** - ✅ **FIXED** - Skip protection preserved while allowing proper state updates to audio_service
  
### Remaining Bluetooth Issues:
  - [ ] **Double-press play after pause** - Audio focus conflicts cause first play command to be ignored, requiring second press
    - **Root cause**: AudioManager audio focus changes interrupt playback immediately after play command
    - **Evidence**: Device logs show `onAudioFocusChange(-1)` immediately after play requests
    - **Solution needed**: Delay audio focus requests or handle focus changes more gracefully
  
### Technical Fixes Implemented:
  - [x] **Skip state masking** - During skip operations, mask transient paused states from audio_service
  - [x] **Dual state listening** - VoidweaverAudioHandler listens directly to just_audio PlayerState for real-time updates
  - [x] **Audio focus optimization** - Removed audio focus requests during skip operations
  - [x] **Processing state masking** - Show consistent ready state during skip transitions

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
- [ ] **Network timeout handling** - Configurable timeouts and retries
- [ ] **Offline mode** - Graceful handling when server unavailable
- [ ] **Structured logging** - Implement proper logging system
- [ ] **Crash reporting** - Add crash analytics for production

## 🧪 Testing & Quality

### Test Coverage
- [x] **Unit tests** - ✅ Comprehensive test suite (113+ passing) covering data models, utilities, sleep timer, caching functionality, and input validation
- [x] **Mock infrastructure** - ✅ Robust AudioPlayer mocking system for reliable testing
- [x] **Testable architecture** - ✅ Refactored AudioPlayerService with dependency injection
- [x] **Caching system tests** - ✅ Added 7 comprehensive tests for API cache, request deduplication, and cache invalidation
- [x] **Input validation tests** - ✅ Added 37 comprehensive tests covering all validation scenarios, edge cases, and security concerns
- [x] **Memory leak prevention tests** - ✅ Added 8 comprehensive tests covering service disposal, timer cleanup, stream subscription management, and resource safety
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
