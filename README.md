# Voidweaver

A high-quality Flutter music player application that connects to Subsonic API-compatible servers for streaming personal music collections. Features advanced ReplayGain audio normalization and clean, optimized code architecture.

## Features

- **Music Streaming**: Stream music from Subsonic, Airsonic, or Navidrome servers
- **Album Browsing**: Browse and play entire albums with cached cover art for fast loading
- **Artist Browsing**: Browse music by artist with alphabetically sorted lists and album grid views
- **Search Functionality**: Comprehensive search for artists, albums, and songs with real-time results
- **Audio Playback**: Full-featured player with play/pause, skip, interactive progress seeking, and next track preloading for seamless transitions
- **Native Media Controls**: Lock screen controls, notification panel controls, and external device support (headphone buttons, Bluetooth)
- **Server Scrobbling**: Automatic server notifications for played songs and listening statistics
  - Now playing notifications when songs start
  - Scrobble submissions for tracking play counts and listening history
  - Smart scrobbling based on song progress (>30 seconds or >50% played)
  - Last.fm integration support (if configured on server)
- **ReplayGain Audio Normalization**: Intelligent volume normalization for consistent playback
  - Client-side ReplayGain metadata extraction from audio files
  - Support for Track and Album normalization modes
  - Real-time volume adjustment with preamp control
  - Automatic fallback for files without ReplayGain data
- **Dark Mode Support**: System-aware dark theme with manual override options
- **Settings Management**: Comprehensive settings page with real-time preview
- **Robust Error Handling**: Comprehensive error handling for playback failures with user-friendly messages
- **Background Sync**: Automatic synchronization with server every 5 minutes
- **Secure Authentication**: Encrypted credential storage with automatic migration from legacy storage
- **Persistent Login**: Remembers server credentials securely between sessions
- **Advanced Image Caching**: Intelligent disk-based caching for album art with offline persistence
- **Cross-Platform**: Runs on Android, iOS, and Web

## Getting Started

### Prerequisites

- Flutter SDK 3.0.0 or later
- A Subsonic-compatible music server (Subsonic, Airsonic, Navidrome, etc.)

### Installation

1. Clone the repository:
   ```bash
   git clone <repository-url>
   cd voidweaver
   ```

2. Install dependencies:
   ```bash
   flutter pub get
   ```

3. Run the application:
   ```bash
   flutter run
   ```

### First Time Setup

1. Launch the app
2. Enter your server details:
   - **Server URL**: Your Subsonic server URL (e.g., `https://music.example.com`)
   - **Username**: Your Subsonic username
   - **Password**: Your Subsonic password
3. Tap "Login" to connect

## Usage

- **Albums Tab**: Browse your music collection by albums
  - Tap any album to start playback
  - Use the menu button (⋮) for additional options
- **Search**: Tap the search icon to find artists, albums, and songs
  - Real-time search with categorized results
  - Tap any result to start playback immediately
- **Now Playing Tab**: View currently playing song with album art, playlist, and interactive progress seeking
- **Lock Screen Controls**: Control playback directly from your device's lock screen with full track information and album art
- **External Device Support**: Use headphone buttons, Bluetooth controls, and other media devices to control playback
- **Shuffle Button**: Play random songs from your collection
- **Settings**: Access via menu (⋮) → Settings
  - **Appearance**: Choose between Light, Dark, or System theme
  - **ReplayGain**: Configure normalization (Off/Track/Album modes)
  - Adjust preamp for overall volume control (-15dB to +15dB)
  - Enable prevent clipping to avoid audio distortion
  - Set fallback gain for files without ReplayGain metadata
- **Sync Indicator**: Shows background synchronization status
- **Error Messages**: Clear feedback when playback fails with actionable error messages

### ReplayGain Audio Normalization

Voidweaver includes advanced ReplayGain support for consistent volume levels:

1. **Automatic Detection**: Reads ReplayGain metadata directly from your audio files
2. **Multiple Formats**: Supports ID3v2 (MP3), APE tags, and Vorbis comments (FLAC/OGG)
3. **Normalization Modes**:
   - **Off**: No volume normalization
   - **Track**: Normalize each song individually for consistent volume
   - **Album**: Preserve album dynamics while normalizing overall level
4. **Real-time Adjustment**: Changes apply immediately to currently playing audio
5. **Intelligent Fallback**: Uses preamp and fallback gain for files without ReplayGain data

## Development

### Running the App

```bash
flutter run -d chrome    # Run in web browser
flutter run              # Run on connected device
```

### Code Quality

✅ **Current Status**: Zero analyzer warnings, optimized performance

```bash
flutter analyze          # Static analysis (currently 0 issues)
flutter test             # Run tests (1/1 passing)
```

**Recent Improvements**:
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

### Building

```bash
flutter build web        # Build for web
flutter build apk        # Build Android APK
flutter build ios        # Build iOS app
```

## Running on Android Phone

### Prerequisites
- Android phone with USB debugging enabled
- Android SDK and ADB installed (comes with Flutter)

### Quick Setup

1. **Enable Developer Options** on your Android phone:
   - Go to Settings → About phone
   - Tap "Build number" 7 times
   - Go back to Settings → Developer options
   - Enable "USB debugging"

2. **Connect your phone**:
   ```bash
   # Connect phone via USB cable
   # Allow USB debugging when prompted on phone
   
   # Verify connection
   flutter devices
   ```

3. **Run the app**:
   ```bash
   flutter run
   ```
   The app will automatically install and launch on your connected Android device.

### Building APK for Easy Installation

To create an APK file you can install on any Android phone:

```bash
# Build release APK
flutter build apk --release

# The APK will be located at:
# build/app/outputs/flutter-apk/app-release.apk
```

You can then:
- Copy the APK to your phone via USB, email, or cloud storage
- Install it by opening the APK file on your phone
- Enable "Install from unknown sources" if prompted

### Troubleshooting Android Setup

- **Device not found**: Ensure USB debugging is enabled and try different USB cables
- **Permission denied**: Accept the USB debugging prompt on your phone
- **Build errors**: Run `flutter doctor` to check for Android SDK issues
- **App crashes**: Check `flutter logs` for detailed error information

## Architecture

Voidweaver uses a clean, optimized architecture with:

- **Provider** pattern for efficient state management
- **Service layer** for API communication, audio playback, ReplayGain processing, and server scrobbling
- **Native audio service integration** for system-level media controls and background playback
- **Client-side metadata extraction** for ReplayGain data from audio files
- **Automatic server notifications** for played songs and listening statistics
- **Responsive UI** with Material Design and comprehensive settings management
- **Background synchronization** for keeping data fresh
- **Efficient HTTP range requests** for metadata extraction with minimal bandwidth usage
- **Performance-optimized widgets** with const constructors and minimal rebuilds
- **Advanced image caching system** with disk-based storage and intelligent placeholder handling
- **Production-ready logging** with proper error handling and debugging capabilities

## Requirements

- **Network Access**: Required for streaming music from your server and metadata extraction
- **Audio Playback**: Uses device audio capabilities with volume control for ReplayGain
- **Secure Storage**: Uses device-level encryption for login credentials and local storage for ReplayGain settings
- **HTTP Range Requests**: Server must support partial content requests for metadata extraction

## License

This project is licensed under the MIT License - see the LICENSE file for details.
