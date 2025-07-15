# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Voidweaver is a Flutter music player application that connects to Subsonic API-compatible servers (Subsonic, Airsonic, Navidrome). It provides music streaming, album browsing, and audio playback functionality.

## Development Commands

```bash
# Run the app
flutter run -d chrome          # Run in Chrome (web)
flutter run                    # Run on connected device/emulator

# Code quality
flutter analyze                # Static analysis and linting
flutter test                   # Run tests (currently minimal)

# Build
flutter build web              # Build for web
flutter build apk              # Build Android APK
flutter build ios             # Build iOS app

# Dependencies
flutter pub get                # Install dependencies
flutter pub upgrade            # Update dependencies
```

## Architecture Overview

### State Management
- **Provider pattern** for state management
- **AppState**: Global application state, server config, album data, background sync
- **AudioPlayerService**: Audio playback state, playlist management, progress tracking

### Key Services
- **SubsonicApi** (`/lib/services/subsonic_api.dart`): Handles API communication with salt-based MD5 authentication, XML parsing, and URL generation
- **AppState** (`/lib/services/app_state.dart`): Manages global state, background sync (5-minute intervals), persistent storage
- **AudioPlayerService** (`/lib/services/audio_player_service.dart`): Audio playback, playlist management, auto-advance, ReplayGain volume normalization
- **SettingsService** (`/lib/services/settings_service.dart`): Manages ReplayGain settings, volume calculations, and persistent configuration
- **ReplayGainReader** (`/lib/services/replaygain_reader.dart`): Client-side ReplayGain metadata extraction from audio files

### UI Architecture
- **HomeScreen**: Main interface with bottom navigation (Albums/Now Playing tabs), settings access via popup menu
- **LoginScreen**: Server configuration and authentication
- **SettingsScreen**: ReplayGain configuration with real-time preview and comprehensive controls
- **Static widgets**: For performance, album art and song info use `StatefulWidget` with change detection to prevent flickering during audio progress updates

### Authentication
- Subsonic protocol with salt-based token authentication
- Credentials stored in SharedPreferences
- Auto-login on app restart

### Background Sync
- Timer-based sync every 5 minutes using `Timer.periodic`
- Visual sync status indicator with idle/syncing/success/error states
- Graceful error handling with retry capabilities

## Data Models

### Core Models (in `subsonic_api.dart`)
- **Album**: Contains id, name, artist, coverArt, songs list
- **Song**: Contains id, title, artist, album, coverArt, duration, ReplayGain metadata (trackGain, albumGain, trackPeak, albumPeak)

### ReplayGain Models (in `replaygain_reader.dart`)
- **ReplayGainData**: Contains trackGain, albumGain, trackPeak, albumPeak values extracted from audio file metadata
- **ReplayGainMode**: Enum for Off/Track/Album normalization modes

### API Integration
- Uses Subsonic API v1.16.1
- XML response parsing with `xml` package
- Supports album listing, song streaming, cover art retrieval
- Implements proper error handling for missing albums/songs

## Performance Considerations

### Image Flickering Prevention
- Album art and song info use separate `StatefulWidget` with change detection
- Only rebuild when song ID actually changes, not on audio progress updates
- Use `ValueKey` for image caching: `ValueKey('main-${song.id}-${song.coverArt}')`

### State Management Patterns
- Use `Consumer<T>` child parameter to prevent unnecessary widget rebuilds
- Separate frequently updating elements (progress bar) from static elements (album art)

## ReplayGain Audio Normalization

### Overview
Voidweaver includes a comprehensive ReplayGain implementation that provides volume normalization for consistent playback across different tracks and albums.

### Features
- **Client-side metadata reading**: Directly extracts ReplayGain data from audio files (ID3v2, APE, Vorbis comments)
- **Multiple normalization modes**: Off, Track-based, Album-based
- **Real-time adjustment**: Settings changes apply immediately to currently playing audio
- **Comprehensive controls**: Preamp adjustment (-15dB to +15dB), prevent clipping, fallback gain
- **Multi-format support**: MP3, M4A, FLAC, OGG and other audio formats

### Implementation Details
- **HTTP range requests**: Fetches only the first 64KB of audio files for metadata extraction
- **Robust parsing**: Handles different ID3v2 versions, APE tags, and Vorbis comments
- **Psychoacoustic calculations**: Proper dB to linear volume conversion with peak limiting
- **Persistent settings**: All ReplayGain preferences saved using SharedPreferences

### Usage
1. Access settings via the three-dot menu → Settings
2. Configure ReplayGain mode (Off/Track/Album)
3. Adjust preamp for overall volume control
4. Enable prevent clipping to avoid distortion
5. Set fallback gain for files without ReplayGain metadata

## Recent Improvements & Fixes

### Code Quality Improvements (Completed ✅)
- **Fixed 148 Flutter analyzer warnings**: All linting issues resolved for optimal performance
- **Added const constructors**: Improved widget performance by reducing unnecessary rebuilds
- **Removed dead code**: Cleaned up unused methods in `home_screen.dart` (`_buildAlbumArt`, `_buildSongInfo`, `_buildPlaylistInfo`)
- **Updated deprecated APIs**: Replaced `withOpacity()` with `withValues()` for better precision
- **Fixed async context usage**: Added proper `mounted` checks to prevent context usage across async gaps
- **Improved logging**: Replaced `print()` statements with `debugPrint()` for production-ready code
- **Updated test suite**: Fixed broken widget test to properly validate app initialization

### Performance Optimizations
- **Const widget optimization**: All static widgets now use const constructors
- **Memory management**: Proper disposal patterns and lifecycle management
- **Build efficiency**: Eliminated unnecessary widget rebuilds through better const usage
- **Import cleanup**: Removed unused imports and dependencies

## Common Issues & Solutions

### Audio Player Integration
- Handle `PlayerState.disposed` case in state listeners
- Use `mounted` checks before `setState()` calls to prevent disposed widget errors
- Implement proper error handling in `playAlbum()` method

### Album Playback Issues (Fixed)
- **Issue**: Albums with empty song lists failing to play
- **Solution**: Improved `playAlbum()` method in `AudioPlayerService` to properly fetch album details when needed
- **Error handling**: Added comprehensive error handling with user-friendly snackbar messages
- **State management**: Proper loading states and error recovery
- **Debugging**: Enhanced logging for troubleshooting playback issues

### ReplayGain Implementation (Completed)
- **Challenge**: Subsonic API doesn't provide ReplayGain metadata
- **Solution**: Custom client-side metadata reader that extracts ReplayGain data directly from audio files
- **Support**: ID3v2 (MP3), APE tags, Vorbis comments (FLAC/OGG), with fallback for files without metadata
- **Performance**: Efficient HTTP range requests minimize bandwidth usage

### API Error Handling
- Check for empty album/song lists before processing
- Graceful fallback for missing cover art
- Proper exception handling with user-friendly error messages
- Enhanced `getAlbum()` method with better error reporting and debugging
- Use `findAllElements()` instead of `findElements()` for more reliable XML parsing

## Dependencies

### Core Dependencies
- `audioplayers: ^6.5.0` - Audio playback
- `provider: ^6.1.1` - State management  
- `http: ^1.1.0` - API communication
- `xml: ^6.3.0` - Subsonic API response parsing
- `crypto: ^3.0.3` - MD5 authentication
- `shared_preferences: ^2.2.2` - Persistent storage

### Development
- `flutter_lints: ^3.0.0` - Linting rules
- Uses standard Flutter testing framework

## Development Environment

### Target Platforms
- Use mostly chrome device for running it. Second priority for now is android.

## Development Preferences

### Default Run Environment
- Try to start the app in the android emulator by default