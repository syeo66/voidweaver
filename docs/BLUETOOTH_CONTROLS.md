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

## Solution: Comprehensive Audio Focus Management

### Implementation Strategy
1. **Skip State Masking** - During skip operations, mask transient paused states from reaching `audio_service`
2. **Direct PlayerState Listening** - `VoidweaverAudioHandler` subscribes directly to `just_audio` PlayerState for real-time updates
3. **Delayed Audio Focus Requests** - Request audio focus with 100ms delay after play to prevent immediate conflicts
4. **Focus State Tracking** - Track audio focus state to avoid unnecessary duplicate requests
5. **Grace Period Handling** - Android-side grace period (300ms) to ignore focus changes immediately after requests
6. **Processing State Consistency** - Show consistent ready state during track transitions

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

#### Audio Focus Management
Implemented sophisticated audio focus handling to prevent conflicts:

```dart
@override
Future<void> play() async {
  // Start playback immediately to avoid delays
  await _audioPlayerService.play();
  
  // Request audio focus with a slight delay to avoid immediate conflicts
  _requestAudioFocusDelayed();
}

void _requestAudioFocusDelayed() {
  _focusRequestTimer?.cancel();
  _focusRequestTimer = Timer(const Duration(milliseconds: 100), () {
    _requestAudioFocus();
  });
}

void _requestAudioFocus() async {
  if (_hasAudioFocus) {
    return; // Already have focus
  }
  
  // Check if we already have system focus
  final hasSystemFocus = await _audioFocusChannel.invokeMethod('hasAudioFocus');
  if (hasSystemFocus == true) {
    _hasAudioFocus = true;
    return;
  }
  
  // Request new focus
  final result = await _audioFocusChannel.invokeMethod('requestAudioFocus');
  _hasAudioFocus = (result == true);
}
```

#### Android-Side Grace Period
```kotlin
private fun handleAudioFocusChange(focusChange: Int) {
  val timeSinceRequest = System.currentTimeMillis() - lastFocusRequestTime
  
  when (focusChange) {
    AudioManager.AUDIOFOCUS_LOSS,
    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
      if (timeSinceRequest > FOCUS_CHANGE_GRACE_PERIOD_MS) {
        // Handle focus loss
      } else {
        // Ignore - too soon after request (likely a conflict)
      }
    }
  }
}
```

## Current Status: ✅ FULLY RESOLVED

### ✅ All Issues Fixed
- **Skip Operations**: Work reliably - no more pause-instead-of-skip
- **Play After Pause**: Single press now resumes playback immediately
- **State Synchronization**: Dual architecture provides consistent state updates
- **Audio Focus Conflicts**: Eliminated through delayed requests and grace periods
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
- Audio focus conflicts: ✅ Eliminated through intelligent timing

## Architecture Benefits

1. **Preservation of Existing Logic**: All skip protection and race condition prevention remains intact
2. **Real-time State Updates**: Bluetooth system receives accurate state information immediately
3. **Separation of Concerns**: Internal app logic separated from system media control requirements
4. **Minimal Risk**: Additive changes only - no removal of existing functionality

## Architecture Achievements

1. **Complete Bluetooth Reliability**: All Bluetooth control operations work as expected
2. **Robust Audio Focus Management**: Intelligent handling prevents conflicts across all scenarios
3. **Comprehensive State Management**: Dual architecture ensures consistent behavior
4. **Production Ready**: Thoroughly tested and validated on real devices

## Related Files

- `lib/services/audio_handler.dart` - Main implementation of dual state architecture
- `lib/services/audio_player_service.dart` - Exposes necessary state for masking
- `test/services/bluetooth_controls_test.dart` - Comprehensive validation tests (5 test cases)
- `TODO.md` - Current status and remaining issues