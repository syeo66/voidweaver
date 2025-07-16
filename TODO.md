# Voidweaver TODO

## 🚨 Critical Issues (Fix First)
- [x] **Verify the played song status is sent** - The status of playing the song should be notified to the server ✅ **COMPLETED**
  - Added `scrobbleNowPlaying()` and `scrobbleSubmission()` methods to SubsonicApi 
  - Implemented automatic now playing notifications when songs start playing
  - Added scrobble submissions for completed songs and progress-based scrobbling for skipped tracks
  - Smart scrobbling logic: only scrobbles songs played >30 seconds or >50% of duration
  - Non-blocking implementation that won't interrupt playback on scrobble failures

## 🔧 Core Functionality Gaps

### Essential Music Player Features
- [ ] **Search functionality** - Search albums, artists, songs
- [ ] **Artist browsing** - Browse by artist (not just albums)
- [ ] **Genre browsing** - Browse music by genre
- [ ] **Queue management** - View, reorder, edit playback queue
- [x] **Progress seeking** - Scrub through tracks with seek bar ✅ **COMPLETED**
  - Replaced read-only progress bar with interactive slider
  - Added tap-to-seek and drag-to-scrub functionality
  - Implemented real-time time labels showing current position and total duration
  - Custom slider styling with proper thumb size and visual feedback
  - Seamless integration with existing AudioPlayerService seekTo() method
- [ ] **Repeat modes** - Repeat track/album/off controls

### Playlist Management (Can those be done on the server side?)
- [ ] **User playlists** - Create, edit, delete custom playlists
- [ ] **Favorite songs** - Mark and browse favorite tracks
- [ ] **Recently played** - Track and display listening history
- [ ] **Smart playlists** - Auto-generated playlists (most played, recent, etc.)

## 🎨 UI/UX Improvements

### Visual Enhancements
- [ ] **Dark mode** - Add dark theme support
- [ ] **Loading states** - Add progress indicators for all operations
- [ ] **Mini player** - Collapsed player view for navigation
- [ ] **Album art animations** - Smooth transitions and effects
- [ ] **Better error messages** - User-friendly error displays

### Mobile Experience
- [ ] **Swipe gestures** - Swipe to skip, seek, etc.
- [ ] **Lock screen controls** - Native media controls integration
- [ ] **Playback notifications** - Show current track in notifications
- [ ] **Landscape support** - Optimize layout for landscape mode
- [ ] **Accessibility** - Screen reader support, better touch targets

### Desktop Experience
- [ ] **Keyboard shortcuts** - Global hotkeys for playback control
- [ ] **System tray** - Minimize to system tray
- [ ] **Native menus** - Platform-appropriate menu bars
- [ ] **File associations** - Open audio files directly

## ⚡ Performance & Architecture

### Code Quality
- [ ] **Input validation** - Robust validation for all user inputs
- [ ] **Error boundaries** - Prevent app crashes with proper error handling

### Performance Optimization
- [x] **Image caching** - Implement proper album art caching ✅ **COMPLETED**
  - Implemented cached_network_image for robust disk-based caching
  - Added automatic placeholder and error handling for better UX
  - Significant performance improvement for image loading and reduced bandwidth usage
  - Images persist across app restarts with intelligent cache management
- [ ] **HTTP/2 support** - Upgrade from HTTP/1.1 for better performance
- [ ] **Request deduplication** - Avoid redundant API calls
- [ ] **Background sync optimization** - Smart sync based on usage patterns

### State Management
- [ ] **Optimize Provider usage** - More specific notifiers to reduce rebuilds
- [ ] **Memory leak prevention** - Proper disposal in all widgets
- [ ] **Local database** - Replace SharedPreferences with SQLite for complex data

## 🔒 Security & Reliability

### Security Improvements
- [x] **Secure credential storage** - Use secure storage instead of SharedPreferences ✅ **COMPLETED**
  - Implemented flutter_secure_storage with device encryption
  - Added Android encrypted shared preferences and iOS keychain integration
  - Automatic migration from legacy SharedPreferences storage
  - Comprehensive error handling for secure storage operations
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

### Documentation
- [ ] **API documentation** - Document all public methods
- [ ] **Contributor guide** - Setup and development instructions
- [ ] **Deployment guide** - Release process documentation

## 🎵 Advanced Features (Future)

### Audio Features
- [ ] **Equalizer** - Add audio EQ controls
- [ ] **Crossfade/gapless playback** - Smooth track transitions
- [ ] **Audio visualizer** - Visual representation of audio
- [ ] **Sleep timer** - Auto-stop functionality
- [ ] **Volume controls** - In-app volume slider

### Extended Features
- [ ] **Offline caching** - Download for offline listening
- [ ] **Lyrics display** - Show synchronized lyrics
- [x] **Scrobbling** - Last.fm integration ✅ **COMPLETED** (Server-side scrobbling implemented)
- [ ] **Multiple servers** - Support multiple Subsonic servers
- [x] **Library statistics** - Play counts, listening time, etc. ✅ **COMPLETED** (Server now tracks play counts via scrobbling)
- [ ] **Backup/restore** - Settings and playlist backup

## 🌐 Platform Support

### Web Platform
- [ ] **CORS handling** - Handle Subsonic server CORS issues
- [ ] **Service workers** - Offline capability for web
- [ ] **Audio format support** - Handle browser audio limitations
- [ ] **Progressive Web App** - Add PWA features

### Mobile Platforms
- [ ] **Background playback** - Ensure works on all platforms
- [ ] **Battery optimization** - Implement power management
- [ ] **Auto-play restrictions** - Handle iOS/web autoplay policies

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
