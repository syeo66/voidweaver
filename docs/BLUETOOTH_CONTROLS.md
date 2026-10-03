# Bluetooth Controls Architecture

## Overview

Voidweaver implements reliable Bluetooth media controls through a dual state architecture that solves synchronization issues between `just_audio` and `audio_service`.

## Problem Background

### Original Issues (Now Resolved)
After migrating from `audioplayers` to `just_audio`, Bluetooth controls experienced reliability problems:
- **Skip commands paused instead of advancing** - ✅ **FIXED** - Skip operations now work reliably
- **Play commands unreliable after pause** - ✅ **FIXED** - Single press now resumes playback after Bluetooth pause
- **State synchronization issues** - ✅ **FIXED** - Dual state architecture provides consistent updates

### Root Cause
During skip operations, `just_audio` temporarily shows `playing=false` while transitioning between tracks. This transient state was being reported to `audio_service`, confusing Bluetooth systems which interpreted it as "user paused playback."

## Solution: Skip State Masking

### Implementation Strategy
1. **Skip State Masking** - During skip operations, mask transient paused states from reaching `audio_service`
2. **Direct PlayerState Listening** - `VoidweaverAudioHandler` subscribes directly to `just_audio` PlayerState for real-time updates
3. **Processing State Consistency** - Show consistent ready state during track transitions

### Technical Details

#### VoidweaverAudioHandler Changes
```dart
class VoidweaverAudioHandler extends BaseAudioHandler with SeekHandler {
  // State masking for skip operations
  bool _lastKnownPlayingState = false;
  
  void _updateSystemPlaybackState(PlayerState playerState) {
    final isSkipping = _audioPlayerService.isSkipOperationInProgress;
    final actualPlaying = playerState.playing;
    
    // Skip state masking: during skip operations, ignore transient paused states
    bool effectivePlaying;
    if (isSkipping && !actualPlaying) {
      // During skip, ignore just_audio's temporary paused state
      effectivePlaying = _lastKnownPlayingState;
    } else {
      // Not skipping or skip completed, use actual state
      effectivePlaying = actualPlaying;
      if (!isSkipping) {
        _lastKnownPlayingState = actualPlaying;
      }
    }
    
    // Update playback state with masked information
    playbackState.add(playbackState.value.copyWith(
      playing: effectivePlaying,
      // ... other state updates
    ));
  }
}
```

#### AudioPlayerService Exposure
```dart
class AudioPlayerService extends ChangeNotifier {
  // Expose AudioPlayer for direct state access by VoidweaverAudioHandler
  AudioPlayer get audioPlayer => _audioPlayer;
  
  // Expose skip operation state for state masking
  bool get isSkipOperationInProgress => _skipOperationInProgress;
}
```

#### Audio Focus
Audio focus is owned entirely by `just_audio`, which requests it through
`audio_session` when playback starts and handles interruptions itself: it
pauses when another app takes focus and resumes when a transient interruption
ends.

The app must not request focus on its own (an earlier version did, through a
`voidweaver/audio_focus` method channel in `MainActivity`). Android treats each
focus listener as a separate client even within one app, so a second request
pushed `just_audio`'s listener down the focus stack. When an interruption
ended, Android handed focus back to the app's own listener, which did nothing,
so `just_audio` never heard that the interruption was over and playback
didn't resume.

## Current Status: ✅ FULLY RESOLVED

### ✅ All Issues Fixed
- **Skip Operations**: Work reliably - no more pause-instead-of-skip
- **Play After Pause**: Single press now resumes playback immediately
- **State Synchronization**: Dual architecture provides consistent state updates
- **Audio Focus**: Left to just_audio/audio_session so interruptions pause and resume correctly
- **Race Conditions**: Skip protection preserved while allowing proper state updates

## Testing

### Validation Approach
1. **Real Device Testing**: Tested on physical Android device with Bluetooth headphones
2. **Log Analysis**: Monitored debug logs to verify state transitions
3. **Comprehensive Testing**: Validated skip operations, pause/play, and rapid commands

### Test Results
- Skip operations: ✅ Reliable single-track advancement
- Pause/Play: ✅ Single press resumes playback immediately
- State consistency: ✅ MediaItem and PlaybackState stay synchronized
- Race conditions: ✅ No double-skipping or state confusion

## Architecture Benefits

1. **Preservation of Existing Logic**: All skip protection and race condition prevention remains intact
2. **Real-time State Updates**: Bluetooth system receives accurate state information immediately
3. **Separation of Concerns**: Internal app logic separated from system media control requirements
4. **Minimal Risk**: Additive changes only - no removal of existing functionality

## Architecture Achievements

1. **Complete Bluetooth Reliability**: All Bluetooth control operations work as expected
2. **Single Audio Focus Owner**: just_audio handles focus and interruptions
3. **Comprehensive State Management**: Dual architecture ensures consistent behavior
4. **Production Ready**: Thoroughly tested and validated on real devices

## Related Files

- `lib/services/audio_handler.dart` - Main implementation of dual state architecture
- `lib/services/audio_player_service.dart` - Exposes necessary state for masking
- `test/services/bluetooth_controls_test.dart` - Native control delegation tests
- `TODO.md` - Current status and remaining issues