# Song Completion Detection

## Problem Description

Sometimes songs do not automatically advance to the next track when they reach the end. This occurs when `just_audio`'s `ProcessingState.completed` event fails to fire due to various timing and buffering issues. To address this, Voidweaver implements three fallback detection mechanisms working in parallel.

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

## Solution: Triple Fallback Detection System

### Implementation Location
`lib/services/audio_player_service.dart`

### Detection Mechanisms

#### 1. Position-Based Detection
**Method**: `_checkManualCompletion(Duration position)` (lines 529-559)

Monitors playback position during active playback to detect when the song is very close to the end:

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

**Trigger Conditions**:
- Position is within 500ms of song end
- Player is actively playing (not paused/stopped)
- Not during a skip operation

#### 2. Stuck Playhead Detection
**Method**: `_checkForStuckPlayback()`

Identifies when the playback position stops advancing in the final 2 seconds of a song, catching cases where network buffering or codec issues cause the player to freeze without triggering completion:

**Trigger Conditions**:
- Position hasn't moved for configured duration (default: 1 second)
- Currently in the last 2 seconds of the song
- Player reports playing state but position is frozen

#### 3. Stop-Based Completion Detection
**Method**: `_checkCompletionOnStop()` (lines 867-906)

Triggers when playback stops or pauses near the end of a song, catching edge cases where the position stream stops updating before the completion event fires:

```dart
void _checkCompletionOnStop() {
  // Only check if we have a current song, valid duration, and aren't already handling a skip
  if (_currentSong == null || _totalDuration == Duration.zero || _skipOperationInProgress) {
    return;
  }

  final currentPosition = _currentPosition;
  final remainingTime = _totalDuration - currentPosition;

  // If we're within 2 seconds of the end, consider this a completion
  const stoppedNearEndThreshold = Duration(seconds: 2);

  if (remainingTime <= stoppedNearEndThreshold && remainingTime >= Duration.zero) {
    // Trigger completion
    _onSongComplete();
  }
}
```

**Trigger Conditions**:
- Playback transitions to stopped or paused state
- Current position is within 2 seconds of song end
- Not during a skip operation
- `just_audio` completion event hasn't fired

**Added**: November 2025 (commit 96c04ca)

### Shared Safety Checks
All three detection mechanisms share common safety checks:
- Disabled during skip operations to prevent conflicts
- Requires valid duration and current song
- Validates just_audio hasn't already completed
- Position-based and stuck playhead detection only active during playback

### Duplicate Prevention
Multiple layers prevent duplicate completion events:
- `_lastManualCompletedSongId` prevents multiple manual completions for same song across all detection mechanisms
- Works alongside existing `_lastCompletedSongId` for just_audio events
- Reset on new playlist/song to allow proper completion detection
- Stop-based detection checks both completion IDs before triggering

### Configuration

#### Tolerance Settings
- **Position-based**: 500ms tolerance accounts for typical network/buffering delays
  - Tight enough to prevent premature advancement
  - Loose enough to catch completion failures
- **Stuck playhead**: Monitors position movement in 2-second window at song end
  - Configurable stuck duration threshold (default: 1 second)
  - Minimum position movement expected (100ms over time periods)
- **Stop-based**: 2-second threshold from song end
  - More generous tolerance catches position stream failures
  - Prevents premature triggering on user pause actions

#### Integration Points
- **Position-based**: Called from `positionStream` listener for real-time checking
- **Stuck playhead**: Analyzed within `_checkManualCompletion()` during position updates
- **Stop-based**: Triggered from PlayerState listener when transitioning to paused/stopped
- All mechanisms trigger the same `_onSongComplete()` method for consistency
- Maintains all existing skip protection logic across all detection types

## Debugging Information

### Log Messages

#### Position-Based Detection
```
[manual_completion] Song appears complete - position: 185s, duration: 186s, remaining: 412ms
[manual_completion] just_audio completion not detected, triggering manual completion
```

#### Stuck Playhead Detection
```
[stuck_playback] Detected stuck position at 184500ms for 1200ms (song: 186000ms)
[manual_completion] Triggering completion due to stuck playback
```

#### Stop-Based Detection
```
[stop_completion] Playback stopped near end - position: 184s, duration: 186s, remaining: 2s
[stop_completion] Triggering completion - playback stopped 1500ms from end
```

### State Variables
- `_lastManualCompletedSongId`: Tracks last manually completed song across all detection mechanisms
- `_lastCompletedSongId`: Tracks just_audio completion events
- `_recentPositions`: Position history for stuck playhead analysis
- Reset in `playAlbum()`, `playRandomSongs()`, and `playSong()` methods

### Testing
- MockAudioPlayer supports completion simulation
- Existing test infrastructure covers completion scenarios  
- No additional test modifications required

## Benefits

1. **Comprehensive Coverage**: Three independent detection mechanisms working in parallel catch completion failures from various sources:
   - Network buffering issues
   - Codec timing problems
   - Position stream update failures
   - Platform-specific audio backend issues
2. **Reliability**: Songs advance consistently even with network/codec issues
3. **Transparency**: Minimal impact on existing architecture
4. **Safety**: Multiple safeguards prevent unwanted behavior across all detection types
5. **Debugging**: Comprehensive logging for issue diagnosis with mechanism-specific tags
6. **Redundancy**: If one detection mechanism misses a completion, others catch it

## Future Considerations

- Monitor log frequency across all three mechanisms to tune tolerances if needed
- Consider adaptive tolerance based on network conditions for each detection type
- Potential server-side duration validation for problematic files
- Analyze which detection mechanism triggers most frequently to optimize thresholds
- Consider making stuck playhead and stop-based thresholds configurable if needed