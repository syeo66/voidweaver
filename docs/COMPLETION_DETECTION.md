# Song Completion Detection

## Problem Description

Sometimes songs do not automatically advance to the next track when they reach the end. This occurs when `just_audio`'s `ProcessingState.completed` event fails to fire due to various timing and buffering issues.

## Root Causes

### just_audio Completion Event Failures

1. **Network Buffering Issues**
   - Streaming songs may not reach the exact reported duration due to network delays
   - Buffer underruns can prevent the completion state from being detected
   - Inconsistent network conditions affect timing precision

2. **Codec-Specific Problems** 
   - Different audio codecs (MP3, FLAC, OGG) may have varying precision in duration reporting
   - Metadata duration vs. actual playback length discrepancies
   - Variable bitrate files can have timing inconsistencies

3. **Platform-Specific Variations**
   - Android ExoPlayer backend timing differences
   - iOS AVPlayer completion detection variations
   - Hardware-specific audio processing delays

## Solution: Manual Completion Fallback

### Implementation Location
`lib/services/audio_player_service.dart:529-559`

### Key Components

#### 1. Position-Based Detection
```dart
void _checkManualCompletion(Duration position) {
  // Check if we're very close to the end (within 500ms tolerance)
  final remainingTime = _totalDuration - position;
  const completionTolerance = Duration(milliseconds: 500);
  
  if (remainingTime <= completionTolerance && remainingTime >= Duration.zero) {
    // Trigger manual completion if just_audio hasn't fired
  }
}
```

#### 2. Safety Checks
- Only active during actual playbook (not paused/stopped)
- Disabled during skip operations to prevent conflicts  
- Requires valid duration and current song
- Validates just_audio hasn't already completed

#### 3. Duplicate Prevention
- `_lastManualCompletedSongId` prevents multiple manual completions for same song
- Works alongside existing `_lastCompletedSongId` for just_audio events
- Reset on new playlist/song to allow proper completion detection

### Configuration

#### Tolerance Setting
- **500ms tolerance** accounts for typical network/buffering delays
- Tight enough to prevent premature advancement
- Loose enough to catch completion failures

#### Integration Points
- Called from `positionStream` listener for real-time checking
- Triggers existing `_onSongComplete()` method for consistency
- Maintains all existing skip protection logic

## Debugging Information

### Log Messages
```
[manual_completion] Song appears complete - position: 185s, duration: 186s, remaining: 412ms
[manual_completion] just_audio completion not detected, triggering manual completion
```

### State Variables
- `_lastManualCompletedSongId`: Tracks last manually completed song
- Reset in `playAlbum()`, `playRandomSongs()`, and `playSong()` methods

### Testing
- MockAudioPlayer supports completion simulation
- Existing test infrastructure covers completion scenarios  
- No additional test modifications required

## Benefits

1. **Reliability**: Songs advance consistently even with network/codec issues
2. **Transparency**: Minimal impact on existing architecture  
3. **Safety**: Multiple safeguards prevent unwanted behavior
4. **Debugging**: Comprehensive logging for issue diagnosis

## Future Considerations

- Monitor log frequency to tune tolerance if needed
- Consider adaptive tolerance based on network conditions
- Potential server-side duration validation for problematic files