# Playback internals

Non-obvious behavior in `lib/services/audio_player_service.dart` and `lib/services/audio_handler.dart`. Most of it works around `just_audio` quirks. Keep it in mind when changing either file.

## Skip protection

Manual skips, native media controls and song completion can all try to advance at the same time, which used to cause double skips. The guards:

- `_skipOperationInProgress` blocks concurrent skips from any source. Manual skips stop playback first so no completion event fires mid-skip.
- `_currentIndex` is the working index. `_confirmedIndex` is the last track that actually started. Auto-advance uses the confirmed index.
- `_lastCompletedSongId` and `_lastManualCompletedSongId` stop the same song from completing twice.
- `_autoAdvanceToNext()` resets `_skipOperationInProgress` and calls `notifyListeners()` in a `finally` block. Without that, a failed advance left the skip buttons stuck loading.
- Skips are debounced (200 ms, `_skipDebounceMs`) in the service, so UI and system controls share the debounce.
- `_indexChangeLog` keeps the last 20 index changes with their source, for debugging.

## Completion fallbacks

`just_audio`'s `ProcessingState.completed` sometimes never fires (buffering, VBR duration mismatch). Two fallbacks call the same `_onSongComplete()`:

| Fallback | Condition | Log tag |
|----------|-----------|---------|
| Position | Playing and within 500 ms of the end | `[manual_completion]` |
| Stuck playhead | In the last 2 s, position hasn't moved for ~1 s | `[stuck_playback]` |

There is deliberately no fallback for the player pausing near the end. `just_audio` keeps `playing` true while buffering and on completion, so ready and not playing only happens after `pause()`. An earlier fallback treated that as completion, so pausing in the last 2 s of a track, or restoring a position there, skipped to the next track.

Both are skipped during a skip operation and respect the completion IDs above. The IDs are reset in `playAlbum()`, `playRandomSongs()` and `playSong()`.

The position fallback is also skipped while a next track is queued for gapless playback (below). Otherwise it would reload the next track 500 ms before the player switches to it on its own.

## Gapless playback

Once the next track is in the audio cache, `_queueNextTrack()` appends it to the player's sequence, and the player moves on to it without a gap. At most one track is queued after the current one:

- `_loadSource()` replaces the whole sequence, so `playAlbum()`, skips, Previous and restoring all reset it. Manual skips still go through the regular reload.
- When `currentIndexStream` reports the queued track's position in the sequence, and the source there is the one that was queued, `_onGaplessTransition()` does what `_onSongComplete()` and `_playSongAtIndex()` would do: scrobbles the finished track, updates the index, applies ReplayGain, sends "now playing" and starts the next preloads. Then it queues the following track.
- Finished tracks stay in the sequence until the next `_loadSource()`, so positions in it never shift. just_audio re-emits the current index with every playback event and sequence change, and an event can carry an index from before the latest change. When the finished track was removed after each transition, such an event pointed at the newly queued track, which was taken for another transition: the service skipped ahead and removed the track that was actually playing.
- Only cached files are queued, never streams. If the network dropped, the player would fail at the transition, while the regular advance can skip ahead to a cached track. If the next track isn't cached by the end of the current one, playback advances as before, with a short gap.
- Changes to the sequence go through `_changeSources()`, which runs them one at a time. Without it, a queue operation that started before a skip could append the old next track after the skip's new source. `_loadSource()` also clears `_queuedNextIndex` as soon as it's called, and nothing is queued while a load is pending, so a transition that happens while a skip is loading is ignored.
- The player's volume applies to the whole sequence, so ReplayGain for the new track is applied just after the transition. In track mode the volume change can be audible right at the boundary; album mode keeps the same gain within an album, so gapless albums play without a jump.

## Bluetooth and system controls

`VoidweaverAudioHandler` listens to `AudioPlayerService` and also directly to `just_audio`'s `playerStateStream`.

During a skip, `just_audio` briefly reports `playing=false`. Bluetooth devices took that as a user pause, so skip turned into pause. The handler masks this: while `isSkipOperationInProgress` is true it reports the last known playing state and a ready processing state.

## Audio focus

`just_audio` owns audio focus through `audio_session`. It pauses on interruptions and resumes after transient ones.

Don't request focus anywhere else, including native code. Android treats each focus listener as a separate client. An earlier `voidweaver/audio_focus` channel in `MainActivity` pushed `just_audio`'s listener down the stack, so when an interruption ended Android notified the wrong listener and playback never resumed.

## Restoring playback

`PlaybackPersistenceService` saves the queue, index and position (throttled to every 5 s while playing, and after every track change). On start, `restorePlaybackState()` loads the saved song paused.

- The source is loaded with `initialPosition` instead of `setUrl()` followed by `seek()`. With a separate seek, load events reporting position 0 could arrive after the seek, so the playhead showed 0:00 while audio resumed at the saved position. `_currentPosition` is also set directly so the UI is right before the player reports anything.
- If loading fails (e.g. offline at startup), `_needsSourceReload` is set and `play()` reloads the song at `_pendingResumePosition`.
- A restored song has no `_currentSongStartTime` until it's played. The first `play()` sets it and sends "now playing", because the song didn't start through `_playSongAtIndex()`. Without a start time it would never be scrobbled.

## Scrobbling

A song is scrobbled once it has played for the minimum play time (default 2 min) or the percentage threshold (default 50%), whichever comes first. Both are configurable in Settings. If neither is reached, the song is still scrobbled when it completes.

Each play is scrobbled at most once, tracked by `_currentSongScrobbled`. The flag is reset whenever a song starts in `_playSongAtIndex()`, so replaying a song (e.g. with Previous) scrobbles it again. Completion checks the flag too, so a song that passed the threshold isn't submitted a second time when it ends. A song restored at a position already past the threshold counts as scrobbled, since that happened in the previous session and the queue persisted it.

Requests go through `ScrobbleQueue`, never directly to the API. The queue:

- is stored in SharedPreferences (`scrobble_queue`) and restored on start
- sends immediately, then retries every 30 s, 100 ms apart
- drops a request after 5 failed attempts or after 7 days

subsoxy uses these scrobbles to tell plays from skips, so the queue's ordering and `playedAt` timestamps matter.
