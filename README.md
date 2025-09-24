# Voidweaver

A high-quality Flutter music player application that streams music from your personal Subsonic-compatible server. Features advanced audio normalization, native media controls, and a clean, responsive interface.

## Features

### 🎵 **Music Streaming**
- **Server Support**: Works with Subsonic, Airsonic, and Navidrome servers
- **Album & Artist Browsing**: Browse your music collection with cached cover art
- **Search**: Real-time search across artists, albums, and songs
- **Playlist Management**: Full-featured player with skip, seek, and queue controls
- **Random Play**: Shuffle through your entire music library
- **Persistent Playback**: Automatically saves and restores your playlist, current track, and playback position across app sessions

### 🎧 **Audio Experience**
- **ReplayGain Audio Normalization**: Intelligent volume normalization for consistent playback
  - Automatic volume adjustment based on track metadata
  - Track or Album normalization modes
  - Preamp control for personal preference
  - Works with MP3, FLAC, and OGG files
- **Native Media Controls**: Reliable control from lock screen, notification panel, and Bluetooth devices with comprehensive audio focus management ensuring single-press reliability
- **Interactive Progress**: Tap or drag to seek to any position in tracks
- **Sleep Timer**: Auto-pause with preset durations (5min to 2 hours)
- **Offline-Resilient Playback**: Multi-track preloading (3 tracks ahead) with automatic fallback during network outages for uninterrupted listening

### 🎨 **Interface & Experience**
- **Dark Mode**: System-aware theme with manual override
- **Landscape Support**: Responsive layouts optimized for both portrait and landscape orientations
- **Fast Loading**: HTTP/2 support with connection reuse and advanced caching for instant response
- **Network Optimization**: Intelligent timeout handling with configurable retry logic and connection presets (Fast/Default/Slow) for different network conditions
- **Enhanced Offline Resilience**: Browse cached content and continue playback with preloaded tracks even during network outages
- **Real-time Updates**: Background sync keeps your library fresh
- **Comprehensive Feedback**: Clear loading states and user-friendly error messages with troubleshooting suggestions
- **Pull-to-Refresh**: Manual refresh on album and artist lists
- **Session Continuity**: Resume exactly where you left off when reopening the app

### 🔒 **Security & Reliability**
- **HTTPS Enforcement**: Mandatory encrypted connections to your music server for secure streaming and credential protection
- **Secure Login**: Encrypted credential storage with automatic session management (flutter_secure_storage v9.2.4)
- **Input Validation**: Comprehensive validation and sanitization of all user inputs to prevent crashes and security issues
- **Error Boundaries**: Global error handling system that prevents app crashes and provides user-friendly error recovery
- **Intelligent Scrobbling**: Automatic play count tracking that submits scrobbles when songs reach the middle (50%) or 2 minute mark, whichever comes first, with duplicate prevention to ensure accurate listening statistics
- **Robust Error Handling**: Graceful recovery from network issues and widget failures
- **Background Sync**: Automatic library updates every 5 minutes
- **Modern Dependencies**: Regularly updated dependencies with comprehensive testing (142+ test suite, last updated August 2025)
- **just_audio Integration**: Enhanced audio performance with dual state synchronization for reliable Bluetooth and native media controls
- **Persistent State Management**: Playlist and playback position automatically saved with validation and error recovery

## Getting Started

### Prerequisites
- A Subsonic-compatible music server (Subsonic, Airsonic, Navidrome, etc.)
- Flutter SDK 3.0.0 or later (for development)

### Build from Source
```bash
git clone <repository-url>
cd voidweaver
make setup                    # Install dependencies
make build-release            # Full validation + release build
```

Or using Flutter directly:
```bash
flutter pub get
flutter build apk --release
```

### First Time Setup

1. **Launch the app**
2. **Enter your server details**:
   - **Server URL**: Your Subsonic server URL with HTTPS (e.g., `https://music.example.com`) - HTTP connections are not allowed for security
   - **Username**: Your Subsonic username
   - **Password**: Your Subsonic password
3. **Tap "Login"** to connect
4. **Start listening** to your music!

## Usage Guide

### Navigation
- **Albums**: Browse your music collection by albums
- **Artists**: Browse by artist with album listings
- **Search**: Find specific artists, albums, or songs
- **Now Playing**: View current track with player controls

### Player Controls
- **Play/Pause**: Tap the play button or use media controls
- **Skip**: Previous/next track buttons with 500ms debouncing to prevent accidental double-taps from both UI controls and system media controls
- **Seek**: Tap or drag the progress bar to jump to any position
- **Shuffle**: Random songs button for discovery
- **Sleep Timer**: Bedtime icon in top bar for auto-pause

### Settings
Access via menu (⋮) → Settings:

#### **Appearance**
- **Theme**: Light, Dark, or System (follows device setting)

#### **Network & Timeouts**
- **Connection Presets**: Fast, Default, or Slow presets optimized for different network conditions
- **Advanced Settings**: Fine-tune connection, request, metadata, and streaming timeouts
- **Retry Configuration**: Configurable retry attempts with exponential backoff
- **Error Recovery**: Intelligent error handling with user-friendly messages and troubleshooting suggestions

#### **ReplayGain Audio Normalization**
- **Mode**: Off, Track (consistent volume), or Album (preserves dynamics)
- **Preamp**: Global volume adjustment (-15dB to +15dB)
- **Prevent Clipping**: Automatic volume reduction to avoid distortion
- **Fallback Gain**: Volume for files without ReplayGain metadata

## ReplayGain Audio Normalization

Voidweaver automatically normalizes audio volume for consistent playback:

1. **Automatic Detection**: Reads volume metadata from your music files
2. **Multiple Modes**:
   - **Track**: Each song at consistent volume
   - **Album**: Preserves album dynamics while normalizing overall level
3. **Real-time Adjustment**: Settings apply immediately to current playback
4. **Smart Fallback**: Handles files without metadata gracefully

## Native Media Controls

Control your music from anywhere with full reliability:

- **Lock Screen**: Full playback control with track info and album art
- **Notification Panel**: Persistent media controls in notification area  
- **Bluetooth Devices**: Headphone buttons and car stereo controls work perfectly with single-press reliability
- **Background Playback**: Continues playing when app is backgrounded
- **Audio Focus Management**: Intelligent handling prevents conflicts and ensures consistent behavior across all control interfaces

## Troubleshooting

### **Connection Issues**
- Verify server URL is correct and accessible (must use https:// - HTTP is not allowed for security)
- Check username and password (no control characters allowed)
- Ensure server supports Subsonic API
- Make sure URL includes protocol and hostname
- **HTTPS Required**: The app only accepts HTTPS connections to protect your credentials and music data

### **Network Timeout Issues**
- **Slow connections**: Try the "Slow Connection" preset in Network & Timeouts settings
- **Frequent timeouts**: Increase timeout values in Advanced Network Settings
- **Connection failures**: Check server accessibility and consider using Fast preset for reliable connections
- **Error messages**: Follow the specific suggestions provided with each error for optimal resolution
- **Network switching**: Try different networks (WiFi vs mobile data) if issues persist

### **Audio Issues**
- **Volume too quiet/loud**: Adjust ReplayGain preamp setting
- **Distortion**: Enable "Prevent Clipping" in ReplayGain settings
- **Inconsistent volume**: Use Track mode for consistent levels
- **Bluetooth controls**: All operations work reliably including skip and play after pause

### **Performance**
- **Slow loading**: App uses HTTP/2 and advanced caching - performance improves with use
- **Missing covers**: Check server configuration for cover art support
- **Sync issues**: Use pull-to-refresh or restart app if needed

## Requirements

- **Android 5.0+** (API level 21) or **iOS 12.0+**
- **Network connection** for streaming and library sync
- **Subsonic-compatible server** with API access enabled

## Privacy & Data

- **No tracking**: No analytics or data collection
- **Local storage**: Only server credentials and app settings
- **Encrypted storage**: Login credentials stored securely on device
- **Server communication**: Only with your configured music server

## Development

For developers interested in contributing or building from source, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for detailed setup instructions, architecture overview, and development guidelines.

## License

This project is licensed under the MIT License - see the LICENSE file for details.