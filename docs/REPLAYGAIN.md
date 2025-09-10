# ReplayGain Implementation Guide

## Overview

Voidweaver includes a comprehensive ReplayGain implementation that provides intelligent volume normalization for consistent audio playback. This document explains how the ReplayGain system works, its features, and technical implementation details.

## What is ReplayGain?

ReplayGain is a technical standard for normalizing the perceived loudness of audio files. It analyzes audio content using psychoacoustic principles and stores metadata about the appropriate volume adjustments needed to achieve consistent playback levels without altering the original audio data.

## Features

### Core Functionality
- **Client-side metadata extraction**: Reads ReplayGain data directly from audio files
- **Multiple normalization modes**: Off, Track, and Album-based normalization
- **Real-time adjustment**: Settings changes apply immediately to currently playing audio
- **Multi-format support**: MP3 (ID3v2), FLAC/OGG (Vorbis comments), and other formats with APE tags

### Advanced Controls
- **Preamp adjustment**: Global volume control from -15dB to +15dB
- **Prevent clipping**: Automatic volume reduction to prevent audio distortion
- **Fallback gain**: Volume adjustment for files without ReplayGain metadata
- **Persistent settings**: All preferences saved automatically

## Usage Guide

### Accessing ReplayGain Settings

1. Open Voidweaver
2. Tap the three-dot menu (⋮) in the top-right corner
3. Select "Settings"
4. Configure ReplayGain options in the settings page

### Configuration Options

#### Normalization Mode
- **Off**: Disables ReplayGain processing (uses only preamp if set)
- **Track**: Normalizes each song individually for consistent volume
- **Album**: Preserves album dynamics while normalizing overall level

#### Preamp Control
- Range: -15dB to +15dB
- Purpose: Global volume adjustment applied to all audio
- Use case: Compensate for overall loudness preferences or equipment characteristics

#### Prevent Clipping
- **Enabled**: Automatically reduces volume if ReplayGain would cause clipping
- **Disabled**: Applies ReplayGain values as-is (may cause distortion)
- Recommended: Keep enabled for best audio quality

#### Fallback Gain
- Range: -15dB to +15dB
- Purpose: Volume adjustment applied to files without ReplayGain metadata
- Use case: Normalize older music files that lack ReplayGain tags

### Real-time Testing

All ReplayGain settings apply immediately to currently playing audio, allowing you to:
- Test different modes while listening
- Fine-tune preamp settings for your preferences
- Verify prevent clipping functionality
- Adjust fallback gain for optimal volume levels

## Technical Implementation

### Metadata Extraction Process

1. **HTTP Range Request**: Fetches first 64KB of audio file for metadata
2. **Format Detection**: Identifies audio format (MP3, M4A, FLAC, etc.)
3. **Tag Parsing**: Extracts ReplayGain data from appropriate metadata format
4. **Volume Calculation**: Converts ReplayGain values to linear volume multipliers

### Supported Metadata Formats

#### ID3v2 Tags (MP3 files)
- **TXXX frames**: `REPLAYGAIN_TRACK_GAIN`, `REPLAYGAIN_ALBUM_GAIN`, `REPLAYGAIN_TRACK_PEAK`, `REPLAYGAIN_ALBUM_PEAK`
- **Versions**: Supports ID3v2.3 and ID3v2.4
- **Encoding**: Handles different text encodings

#### Vorbis Comments (FLAC/OGG files)
- **Fields**: `REPLAYGAIN_TRACK_GAIN=`, `REPLAYGAIN_ALBUM_GAIN=`, etc.
- **Format**: Standard Vorbis comment format
- **Location**: Within FLAC metadata blocks or OGG comment headers

#### APE Tags
- **Fields**: Same naming convention as Vorbis comments
- **Location**: APE tag headers in various audio formats
- **Parsing**: Basic APE tag structure recognition

### Volume Calculation Algorithm

```dart
// Basic ReplayGain calculation
double gainToUse = (mode == track) ? trackGain : albumGain;
double totalGain = gainToUse + preamp;
double volumeMultiplier = pow(10.0, totalGain / 20.0);

// Apply clipping prevention
if (preventClipping && peak > 0) {
  double peakAfterGain = peak * volumeMultiplier;
  if (peakAfterGain > 1.0) {
    volumeMultiplier = 1.0 / peak;
  }
}
```

### Performance Optimizations

- **Efficient requests**: Only downloads first 64KB of files for metadata
- **Caching**: ReplayGain data attached to Song objects for reuse
- **Instant volume application**: ReplayGain volume is applied before audio playback starts, eliminating audible volume changes
- **Preloading integration**: ReplayGain metadata cached during background preloading for immediate volume-correct playback
- **Asynchronous processing**: Metadata extraction doesn't block audio playback
- **Error handling**: Graceful fallback when metadata extraction fails
- **Optimized code quality**: Zero analyzer warnings with const constructors for minimal widget rebuilds
- **Production logging**: Uses `debugPrint()` for proper debug output management
- **Object equality optimization**: Proper equality operators prevent unnecessary UI rebuilds during ReplayGain processing
- **Minimal object creation**: ReplayGain processing only creates new Song objects when metadata actually changes

## Troubleshooting

### Common Issues

#### No ReplayGain Data Found
- **Cause**: Audio files don't contain ReplayGain metadata
- **Solution**: Use fallback gain setting or generate ReplayGain tags with tools like mp3gain, foobar2000, or MusicBrainz Picard

#### Volume Too Quiet/Loud
- **Solution**: Adjust preamp setting
- **Track mode**: Use for consistent volume across all songs
- **Album mode**: Preserves artistic intent within albums

#### Distortion/Clipping
- **Cause**: ReplayGain gain values causing volume to exceed 100%
- **Solution**: Enable "Prevent Clipping" option
- **Alternative**: Reduce preamp setting

#### Inconsistent Volume
- **Cause**: Mix of files with and without ReplayGain metadata
- **Solution**: Set appropriate fallback gain for files without metadata

### Debug Information

The app provides detailed debug output in the console showing:
- ReplayGain metadata extraction status
- Applied volume multipliers
- Current settings (mode, preamp, fallback gain)
- Whether metadata or fallback gain is being used

## Best Practices

### For Users
1. **Start with Track mode** for consistent volume across your library
2. **Use Album mode** for classical music or concept albums
3. **Adjust preamp** based on your listening preferences and equipment
4. **Keep prevent clipping enabled** unless you have specific audio equipment requirements
5. **Set fallback gain** to match the average level of your ReplayGain-enabled tracks

### For Developers
1. **Test with various audio formats** to ensure broad compatibility
2. **Handle parsing errors gracefully** with appropriate fallbacks
3. **Minimize bandwidth usage** through efficient HTTP range requests
4. **Provide clear user feedback** about ReplayGain status and functionality
5. **Implement proper volume calculations** following ReplayGain specifications

## Standards Compliance

Voidweaver's ReplayGain implementation follows:
- **ReplayGain 1.0 specification** for volume calculations
- **ID3v2.3/2.4 standards** for MP3 metadata parsing
- **Vorbis comment specification** for FLAC/OGG metadata
- **APE tag standards** for additional format support

## Future Enhancements

Potential improvements for future versions:
- **MP4/M4A metadata support** for iTunes-style ReplayGain tags
- **Automatic ReplayGain calculation** for files without metadata
- **EBU R128 loudness support** for broadcast-standard normalization
- **Playlist-based normalization** for mixed content playback
- **Advanced DSP options** for additional audio processing

## References

- [ReplayGain Official Specification](https://wiki.hydrogenaudio.org/index.php?title=ReplayGain_specification)
- [ID3v2.4 Tag Specification](https://id3.org/id3v2.4.0-structure)
- [Vorbis Comment Specification](https://www.xiph.org/vorbis/doc/v-comment.html)
- [APE Tag Specification](https://wiki.hydrogenaudio.org/index.php?title=APE_key)