# Playback internals

Non-obvious behavior in `lib/services/audio_player_service.dart` and `lib/services/audio_handler.dart`. Most of it works around `just_audio` quirks. Keep it in mind when changing either file.

## The player owns the queue

`_loadQueue()` hands the whole playlist to `just_audio` with `setAudioSources()` (lazy preparation). The player moves from track to track by itself, gaplessly, and the service follows its current index. There is no completion logic of its own in the service: `ProcessingState.completed` only means the end of the playlist.

Earlier versions loaded one track at a time and advanced on `completed`. That event sometimes didn't fire, which needed fallbacks (near the end, stuck playhead, paused near the end), which in turn caused double skips and skips on pause. Don't bring them back: within a sequence the player advances without them.

- Every source is tagged with a `_QueueEntry` (generation and playlist index). `_followPlayer()` maps the player's current index to its entry, so a sequence position always resolves to the right song. Entries of an older generation (a replaced sequence) are ignored.
- Only an advance by one counts as the player moving on (`_followPlayer()`): it scrobbles the finished track, then sends "now playing", applies ReplayGain and starts the next downloads. `just_audio` re-emits the current index with every playback event, so repeated and backwards events are ignored.
- Changes to the player's index or sequence go through `_playerOp()`, one at a time. Index events are ignored while one runs, and the service catches up with the player afterwards.
- After a skip, `_awaitedIndex` holds the target until the player reports it. Until then an event can still be from before the seek; after Previous, the old track's index would look like an advance.
- The player's volume applies to the whole sequence, so ReplayGain for the next track is applied just after the player moves on. In track mode the change can be audible right at the boundary; album mode keeps the same gain within an album. Skips apply it before seeking.

## Downloads in the queue

Tracks already in the audio cache go into the sequence as files, the rest as streams. While a track plays, the next 3 are downloaded (see [CACHING.md](CACHING.md)), and `_useCachedFile()` replaces each one's stream with the file. The track then plays without the network and isn't downloaded a second time.

- The file is inserted before the stream is removed, and only after the current track, so positions up to the current track never shift.
- The next track is left alone in the last 10 s of the current one (`_swapCutoff`), when the player may already be moving on to the stream. Removing the item the player just moved to would skip it.
- `_fileBacked` records which positions are files, so nothing is swapped twice.

## Load errors

A track that can't load (offline and not downloaded, or a stream breaking off) is reported on `errorStream`. `_onPlayerError()` continues at the next downloaded track; if there is none, playback stops on the failing track and the next `play()` loads the queue again from there. Errors while a `_playerOp()` runs are handled once it finishes. `setAudioSources()` throws its own errors, and `_loadQueue()` handles them the same way.

After `stop()` or an error the player is idle, so `play()` and skips load the queue again (`_loadQueue()`) instead of seeking.

## Skips

- `next()` and `previous()` seek within the sequence (`_jumpTo()`). Nothing is reloaded, and a downloaded target plays from its file.
- Skips are debounced (200 ms, `_skipDebounceMs`) in the service, so UI and system controls share the debounce. `_skipOperationInProgress` blocks a skip while another runs, and is reset in a `finally` block so the skip buttons can't get stuck.
- A skip scrobbles the current track if it passed the threshold.

There is deliberately no handling for the player pausing near the end of a track: `just_audio` keeps `playing` true while buffering and on completion, so ready and not playing only happens after `pause()`.

## Bluetooth and system controls

`VoidweaverAudioHandler` listens to `AudioPlayerService` and also directly to `just_audio`'s `playerStateStream`.

When skips reloaded the source, `just_audio` briefly reported `playing=false`. Bluetooth devices took that as a user pause, so skip turned into pause. The handler masks this: while `isSkipOperationInProgress` is true it reports the last known playing state and a ready processing state. Skips now seek within the queue, which keeps `playing`, but a skip after `stop()` or an error still loads the queue again.

`audio_service` ends everything when the handler reports `idle`: it removes the notification, deactivates the media session (Bluetooth controls stop working) and stops the foreground service, after which Android stops the app in the background. The player is idle after every load error, including those the service recovers from by continuing at a downloaded track. So the handler reports `idle` only once `isStopped` is set (`stop()`, or nothing loaded yet). Otherwise an idle player shows as loading while playing, or as ready while paused. A failed load pauses the player, so the system doesn't show it as loading indefinitely.

## Audio focus

`just_audio` owns audio focus through `audio_session`. It pauses on interruptions and resumes after transient ones.

Don't request focus anywhere else, including native code. Android treats each focus listener as a separate client. An earlier `voidweaver/audio_focus` channel in `MainActivity` pushed `just_audio`'s listener down the stack, so when an interruption ended Android notified the wrong listener and playback never resumed.

## Restoring playback

`PlaybackPersistenceService` saves the queue, index and position (throttled to every 5 s while playing, and after every track change). On start, `restorePlaybackState()` loads the saved song paused.

- The queue is loaded with `initialIndex` and `initialPosition` instead of a `seek()` afterwards. With a separate seek, load events reporting position 0 could arrive after the seek, so the playhead showed 0:00 while audio resumed at the saved position. `_currentPosition` is also set directly so the UI is right before the player reports anything.
- If loading fails (e.g. offline at startup), `_needsSourceReload` is set and `play()` loads the queue again at `_pendingResumePosition`. Restoring never skips ahead to a downloaded track.
- A restored song has no `_currentSongStartTime` until it's played. The first `play()` sets it, sends "now playing" and starts the downloads. Without a start time it would never be scrobbled.

## Scrobbling

A song is scrobbled once it has played for the minimum play time (default 2 min) or the percentage threshold (default 50%), whichever comes first. Both are configurable in Settings. If neither is reached, the song is still scrobbled when it completes.

Each play is scrobbled at most once, tracked by `_currentSongScrobbled`. The flag is reset whenever a song starts (`_setCurrentTrack()`), so replaying a song (e.g. with Previous) scrobbles it again. Completion checks the flag too, so a song that passed the threshold isn't submitted a second time when it ends. A song restored at a position already past the threshold counts as scrobbled, since that happened in the previous session and the queue persisted it.

Requests go through `ScrobbleQueue`, never directly to the API. The queue:

- is stored in SharedPreferences (`scrobble_queue`) and restored on start
- sends immediately, then retries every 30 s, 100 ms apart
- drops a request after 5 failed attempts or after 7 days

subsoxy uses these scrobbles to tell plays from skips, so the queue's ordering and `playedAt` timestamps matter.
