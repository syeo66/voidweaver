# Voidweaver TODO

## 🚨 Critical Issues (Fix First)

## 🔧 Core Functionality Gaps

## 🎨 UI/UX Improvements

### Visual Enhancements
- [ ] **Album art animations** - Smooth transitions and effects
- [ ] **Organize search results in tabs**

### Mobile Experience
- [ ] **Swipe gestures** - Swipe to skip, seek, etc.
- [ ] **Landscape support** - Optimize layout for landscape mode

## ⚡ Performance & Architecture

### Code Quality
- [ ] **Input validation** - Robust validation for all user inputs
- [ ] **Error boundaries** - Prevent app crashes with proper error handling

### Performance Optimization
- [ ] **HTTP/2 support** - Upgrade from HTTP/1.1 for better performance
- [ ] **Request deduplication** - Avoid redundant API calls
- [ ] **Background sync optimization** - Smart sync based on usage patterns

### State Management
- [ ] **Optimize Provider usage** - More specific notifiers to reduce rebuilds
- [ ] **Memory leak prevention** - Proper disposal in all widgets
- [ ] **Local database** - Replace SharedPreferences with SQLite for complex data

## 🔒 Security & Reliability

### Security Improvements
- [ ] **HTTPS enforcement** - Require HTTPS for server connections
- [ ] **Certificate validation** - Proper handling of self-signed certificates
- [ ] **Credential validation** - Better login validation and feedback

### Error Handling
- [ ] **Network timeout handling** - Configurable timeouts and retries
- [ ] **Offline mode** - Graceful handling when server unavailable
- [ ] **Structured logging** - Implement proper logging system
- [ ] **Crash reporting** - Add crash analytics for production

## 🧪 Testing & Quality

### Test Coverage
- [ ] **Unit tests** - Test all services and business logic
- [ ] **Integration tests** - Test complete user workflows
- [ ] **Audio playback tests** - Test core playback functionality
- [ ] **ReplayGain tests** - Test complex volume calculation logic

## 🎵 Advanced Features (Future)

### Audio Features
- [ ] **Sleep timer** - Auto-stop functionality
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
