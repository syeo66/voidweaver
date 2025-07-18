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
- [x] **Preload next track** ✅ **COMPLETED**
  - Automatically preloads the next song's stream URL when current song starts playing
  - Uses preloaded URL for instant playback when user skips to next track
  - Smart caching prevents unnecessary preloading of already cached tracks
  - Memory efficient implementation that only preloads URLs, not audio data
  - Preload state is cleared when playlist changes to prevent stale data
  - Added preload status tracking with `isPreloading` and `preloadedSong` getters
- [x] **Search functionality** - Search albums, artists, songs ✅ **COMPLETED**
  - Added comprehensive search using Subsonic search3 endpoint
  - Real-time search with 500ms debounce and categorized results display
  - Created dedicated search screen with Artists, Albums, and Songs sections
  - Seamless integration with existing audio player functionality
  - Robust XML parsing with namespace support for Subsonic API responses
  - Advanced image caching for search result cover art
  - Search accessible via search icon in home screen app bar
- [x] **Artist browsing** - Browse by artist (not just albums) ✅ **COMPLETED**
  - Added `getArtists()` and `getArtistAlbums()` methods to SubsonicApi
  - Created dedicated artist browsing screen with alphabetically sorted artist list
  - Artist avatars using cover art or initials with album counts
  - Album grid view for selected artists with tap-to-play functionality
  - Integrated into home screen bottom navigation as "Artists" tab
  - Comprehensive error handling and loading states
- [ ] **Queue management** - View, reorder, edit playback queue
- [x] **Progress seeking** - Scrub through tracks with seek bar ✅ **COMPLETED**
  - Replaced read-only progress bar with interactive slider
  - Added tap-to-seek and drag-to-scrub functionality
  - Implemented real-time time labels showing current position and total duration
  - Custom slider styling with proper thumb size and visual feedback
  - Seamless integration with existing AudioPlayerService seekTo() method

### Playlist Management (Can those be done on the server side?)
- [ ] **User playlists** - Create, edit, delete custom playlists (if Subsonic allows it)
- [ ] **Favorite songs** - Mark and browse favorite tracks (if Subsonic allows it)
- [ ] **Recently played** - Track and display listening history (if Subsonic allows it)
- [ ] **Smart playlists** - Auto-generated playlists (most played, recent, etc.) (if subsonic allows it)

## 🎨 UI/UX Improvements

### Visual Enhancements
- [x] **Dark mode** - Add dark theme support ✅ **COMPLETED**
  - Added `ThemeMode` support to SettingsService with System/Light/Dark options
  - Updated main.dart to support light/dark themes with system detection
  - Created appearance settings section in settings screen
  - Persistent theme preference storage using SharedPreferences
  - Seamless theme switching without app restart through reactive Provider pattern
  - Consistent theming across all screens using Flutter's built-in theme system
- [x] **Loading states** - Add progress indicators for all operations ✅ **COMPLETED**
  - Added `LoadingState` enum to AppState with granular states for configuration and album operations
  - Added `AudioLoadingState` enum to AudioPlayerService for different audio operations (album loading, random songs, individual tracks, preloading)
  - Enhanced login screen with configuration loading states, disabled form fields during loading, and improved error display with retry functionality
  - Added loading indicators to shuffle button and album tiles with proper error handling
  - Enhanced search screen with loading indicators in search field prefix and better loading state management
  - Improved artist screen with loading states for both artist list and album loading, pull-to-refresh functionality, and enhanced empty states
  - Added context-safe async operations with proper BuildContext handling across async gaps
  - Implemented comprehensive error handling with user-friendly messages and retry mechanisms throughout the app
  - Added progress indicators in UI elements including buttons, search fields, and navigation elements
  - All loading states maintain proper UI feedback and prevent user interaction during operations
- [ ] **Mini player** - Collapsed player view for navigation
- [ ] **Album art animations** - Smooth transitions and effects
- [x] **Better error messages** - User-friendly error displays ✅ **COMPLETED** (Implemented as part of loading states)
- [ ] **Organize search results in tabs**

### Mobile Experience
- [x] **Lock screen controls** - Native media controls integration ✅ **COMPLETED**
  - Added audio_service package for comprehensive native media controls
  - Created VoidweaverAudioHandler for system-level media control integration
  - Updated Android configuration with AudioServiceActivity and proper manifest permissions
  - Supports lock screen controls, notification panel controls, and external device input
  - Real-time media metadata updates including track info, album art, and playback progress
  - Background playback continuation when app is backgrounded or device is locked
- [x] **Playback notifications** - Show current track in notifications ✅ **COMPLETED**
  - Persistent media notification with play/pause/skip controls
  - Displays current track metadata, album artwork, and playback progress
  - Proper MediaBrowserService configuration for Android system integration
- [ ] **Swipe gestures** - Swipe to skip, seek, etc.
- [ ] **Landscape support** - Optimize layout for landscape mode
- [ ] **Accessibility** - Screen reader support, better touch targets

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
- [x] **Background playback** - Ensure works on all platforms ✅ **COMPLETED** (Android implemented)
  - Implemented comprehensive background playback for Android using audio_service
  - Proper foreground service configuration for uninterrupted playback
  - System-level media session handling for seamless background operation
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
