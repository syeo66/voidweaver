# Playback internals

Non-obvious behavior in `lib/services/audio_player_service.dart` and `packages/voidweaver_player`. Keep it in mind when changing either.

The player is `VoidweaverPlayer` from the local plugin `packages/voidweaver_player`: a thin layer over Media3 ExoPlayer (`PlaylistPlayer.java`) with a gain stage per item (`GainAudioProcessor.java`) and a Media3 media session for the system controls. It replaced `just_audio`, which had no way to apply a gain per track, and `audio_service`.

## The player owns the queue

`_loadQueue()` hands the whole playlist to the player with `setAudioSources()`. The player moves from track to track by itself, gaplessly, and the service follows its current index. There is no completion logic of its own in the service: `ProcessingState.completed` only means the end of the playlist.

At the end of the playlist the player stays `completed` with `playing` still set. The system controls show that as playing, and `play()` does nothing in that state. `_onQueueCompleted()` therefore pauses the player at the start of the last track. Play replays it as a new play: it gets a start time and "now playing" on `play()`, like a restored song, and is scrobbled again. The completed event that follows the pause has `playing` false and is ignored.

Earlier versions loaded one track at a time and advanced on `completed`. That event sometimes didn't fire, which needed fallbacks (near the end, stuck playhead, paused near the end), which in turn caused double skips and skips on pause. Don't bring them back: within a sequence the player advances without them.

- Every source is tagged with a `_QueueEntry` (generation and playlist index). `_followPlayer()` maps the player's current index to its entry, so a sequence position always resolves to the right song. Entries of an older generation (a replaced sequence) are ignored.
- Only an advance by one counts as the player moving on (`_followPlayer()`): it scrobbles the finished track, then sends "now playing", and starts the next downloads. Index events can repeat or arrive late, so repeated and backwards events are ignored.
- Changes to the player's index or sequence go through `_playerOp()`, one at a time. Index events are ignored while one runs, and the service catches up with the player afterwards.
- After a skip, `_awaitedIndex` holds the target until the player reports it. Until then an event can still be from before the seek; after Previous, the old track's index would look like an advance.

## ReplayGain per track

Every item in the sequence carries its own gain (`AudioSource.gain`, from `_gainFor()`). On the native side, `GainAudioProcessor` sits in ExoPlayer's audio sink and multiplies the decoded samples by the gain of the item they belong to. The sink drains its processors and flushes them with the next item's `StreamMetadata` exactly where one item's samples end, so the gain changes at the sample where the track changes, also during a gapless transition. Nothing is applied when the player reports the new index; that event arrives a few hundred ms later, after the new track is already audible.

- Gains can be above 1 (quiet tracks, positive preamp); samples are clipped at full scale. With clipping prevention on, the peak keeps them below that.
- A gain read later (from a downloaded file, or by a range request) is set on the song's items with `_updateGains()`. The start track's gain is read before the queue is loaded, and a skip's target before seeking.
- Changed settings apply to every item at once (`refreshReplayGainVolume()`).
- Each switch to a new item is logged with the tag `VoidweaverGain` (`adb logcat -s VoidweaverGain`).
- Track mode still changes the level between songs that run into each other (live albums, mixes), since each has its own gain. Album mode keeps one gain within an album.

## Downloads in the queue

Tracks already in the audio cache go into the sequence as files, the rest as streams. While a track plays, the next 3 are downloaded (see [CACHING.md](CACHING.md)), and `_useCachedFile()` replaces each one's stream with the file. The track then plays without the network and isn't downloaded a second time.

- The file is inserted before the stream is removed, and only after the current track, so positions up to the current track never shift.
- The next track is left alone in the last 10 s of the current one (`_swapCutoff`), when the player may already be moving on to the stream. Removing the item the player just moved to would skip it.
- `_fileBacked` records which positions are files, so nothing is swapped twice.

## Load errors

A track that can't load (offline and not downloaded, or a stream breaking off) is reported on `errorStream`. `_onPlayerError()` continues at the next downloaded track; if there is none, playback stops on the failing track and the next `play()` loads the queue again from there. Errors while a `_playerOp()` runs are handled once it finishes. If `_jumpTo()`'s target failed, it then leaves playback to `_onPlayerError()` instead of starting it.

The player's `seek()` completes once the target is ready or has failed (the error arrives on `errorStream` first). With `just_audio`, a seek to a target that failed never completed; awaited inside a `_playerOp()`, that blocked every later operation. `_seekToItem()` still stops waiting once the player reports an error or goes idle, so a seek that never completes can't block playback again. `setAudioSources()` completes once the start item is ready and throws its own errors, and `_loadQueue()` handles them the same way.

After `stop()` or an error the player is idle, so `play()` and skips load the queue again (`_loadQueue()`) instead of seeking.

## Skips

- `next()` and `previous()` seek within the sequence (`_jumpTo()`). Nothing is reloaded, and a downloaded target plays from its file.
- Skips are debounced (200 ms, `_skipDebounceMs`) in the service, so UI and system controls share the debounce. `_skipOperationInProgress` blocks a skip while another runs, and is reset in a `finally` block so the skip buttons can't get stuck.
- A skip scrobbles the current track if it passed the threshold.

There is deliberately no handling for the player pausing near the end of a track: the player keeps `playing` true while buffering and on completion, so ready and not playing only happens after `pause()`.

## Bluetooth and system controls

The plugin's Media3 `MediaSession` drives the notification, the lock screen player and Bluetooth/media button controls (`PlaybackService`, a `MediaSessionService`, hosts it; Media3 builds the notification and keeps the service in the foreground while playing). The session shows the ExoPlayer's real state and the metadata of the current queue item (`AudioSource.title` etc.), so it follows gapless transitions by itself.

- **Commands go to Dart.** The session talks to `SessionPlayer`, which forwards every command (play, pause, stop, next, previous, seek) to Dart instead of acting on the ExoPlayer. `AudioPlayerService` handles them (`_onSystemCommand()`) with the same methods as the app's own buttons, so skips are debounced, scrobbled and reload the queue after an error like any other. Only these commands are available to controllers; nobody else can change the queue.
- **Every controller gets full control** (`FullControlCallback` in `PlaylistPlayer`). By default Media3 gives untrusted controllers read access only, and it can't verify apps that package visibility hides from this one, such as launchers with a media widget (Niagara): they showed the track but their buttons did nothing. With only transport controls on offer, a controller can't do more than a Bluetooth button.
- **Load errors don't end the session.** The ExoPlayer is idle after every load error, also when the service recovers by continuing at a downloaded track or waits for Play to load again. An idle session would remove the notification and stop the foreground service. So `SessionPlayer` reports an idle player as ready (paused, without the error) unless playback was stopped. Only `stop()` ends the notification (`SHOW_NOTIFICATION_FOR_IDLE_PLAYER_NEVER`), and the next play brings it back.
- **One session per player.** Each `VoidweaverPlayer` (one per login) has its own session; disposing it on logout releases the session and removes the notification. `PlaybackService` stops once no session is left.
- **The Dart engine outlives the activity.** Playlist logic, scrobbling and downloads run in Dart, so `MainActivity` keeps its `FlutterEngine` in `FlutterEngineCache`. Closing the activity (Back, swiping it from the recents) leaves the engine running; a new activity attaches to it.
- **Swiped away while paused**, Media3 stops `PlaybackService`. The session stays, so media buttons still reach it, and the next play starts the service again (`PlaybackService.ensureStarted()`).
- There is no playback resumption after the process has died (no `MediaButtonReceiver`): a media button then does nothing until the app is opened.

## Audio focus

ExoPlayer owns audio focus (`setAudioAttributes(..., handleAudioFocus = true)` in `PlaylistPlayer`). It pauses on interruptions and resumes after transient ones; while focus is lost for a moment the player reports `playing` false. It also pauses when headphones are unplugged (`setHandleAudioBecomingNoisy`).

Don't request focus anywhere else, including native code. Android treats each focus listener as a separate client. An earlier `voidweaver/audio_focus` channel in `MainActivity` pushed the player's listener down the stack, so when an interruption ended Android notified the wrong listener and playback never resumed.

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
- sends oldest first, 100 ms apart, as soon as a request is queued and every 30 s
- keeps a submission that can't be sent (network error, HTTP error, or the server refusing the credentials) at the front and stops there, so later requests never overtake it. It's retried on the next timer tick or the next queued request, and dropped only after 7 days.
- drops a submission the server rejects for itself (a `status="failed"` response that isn't an auth error, e.g. unknown song)
- drops a "now playing" that fails, since it would be stale by the time it's retried

subsoxy uses these scrobbles to tell plays from skips, so the queue's ordering and `playedAt` timestamps matter. That's also why `scrobbleNowPlaying()` and `scrobbleSubmission()` throw on failure: the queue has to know.
