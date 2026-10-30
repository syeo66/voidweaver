# Playback internals

Non-obvious behavior in `lib/services/audio_player_service.dart` and `packages/voidweaver_player`. Keep it in mind when changing either.

The player is `VoidweaverPlayer` from the local plugin `packages/voidweaver_player`: a thin layer over Media3 ExoPlayer (`PlaylistPlayer.java`) with a gain stage per item (`GainAudioProcessor.java`) and a Media3 media session for the system controls. It replaced `just_audio`, which had no way to apply a gain per track, and `audio_service`.

## The player owns the queue

`_loadQueue()` hands the whole playlist to the player with `setAudioSources()`. The player moves from track to track by itself, gaplessly, and the service follows its current index. There is no completion logic of its own in the service: `ProcessingState.completed` only means the end of the playlist.

At the end of the playlist the player stays `completed` with `playing` still set. The system controls show that as playing, and `play()` does nothing in that state. `_onQueueCompleted()` therefore pauses the player at the start of the last track. Play replays it as a new play: it gets a start time and "now playing" on `play()`, like a restored song, and is scrobbled again. The completed event that follows the pause has `playing` false and is ignored.

Earlier versions loaded one track at a time and advanced on `completed`. That event sometimes didn't fire, which needed fallbacks (near the end, stuck playhead, paused near the end), which in turn caused double skips and skips on pause. Don't bring them back: within a sequence the player advances without them.

- Every source is tagged with a `_QueueEntry` (generation and playlist index). `_followPlayer()` maps the player's current index to its entry, so a sequence position always resolves to the right song. Entries of an older generation (a replaced sequence) are ignored.
- Only an advance by one counts as the player moving on (`_followPlayer()`): it scrobbles the finished track if it was heard past the threshold, then sends "now playing", and starts the next downloads. Index events can repeat or arrive late, so repeated and backwards events are ignored.
- Changes to the player's index or sequence go through `_playerOp()`, one at a time. Index events are ignored while one runs, and the service catches up with the player afterwards.
- After a skip, `_awaitedIndex` holds the target until the player reports it. Until then an event can still be from before the seek; after Previous, the old track's index would look like an advance.

## ReplayGain per track

Every item in the sequence carries its own gain (`AudioSource.gain`, from `_gainFor()`). On the native side, `GainAudioProcessor` sits in ExoPlayer's audio sink and multiplies the decoded samples by the gain of the item they belong to. The sink drains its processors and flushes them with the next item's `StreamMetadata` exactly where one item's samples end, so the gain changes at the sample where the track changes, also during a gapless transition. Nothing is applied when the player reports the new index; that event arrives a few hundred ms later, after the new track is already audible.

- Gains can be above 1 (quiet tracks, positive preamp); samples are clipped at full scale. With clipping prevention on, the peak keeps them below that.
- A gain read later (from a downloaded file, or by a range request) is set on the song's items with `_updateGains()`. The start track's gain is read before the queue is loaded, and a skip's target before seeking.
- Changed settings apply to every item at once (`refreshReplayGainVolume()`).
- Each switch to a new item is logged with the tag `VoidweaverGain` (`adb logcat -s VoidweaverGain`).
- Track mode still changes the level between songs that run into each other (live albums, mixes), since each has its own gain. Album mode keeps one gain within an album. Smart mode picks between them by the queue's source (`_playlistSource == QueueSource.album`, also after a restore).

## Downloads and the cache

Every item in the sequence is a stream URL with a cache key (server and song id, `AudioCache.keyFor()`). The player reads through its Media3 cache, so a cached track plays without the network wherever it is in the queue, and the track that's playing is cached as it streams. While a track plays, the next 3 are downloaded into the same cache (see [CACHING.md](CACHING.md)). The queue itself never changes for that; earlier versions swapped streams for downloaded files in the sequence, which needed care around the track the player was about to move to.

## Load errors

The player retries a failed load 8 times, about 25 s in all (`LOAD_RETRY_COUNT` in `PlaylistPlayer`), before it reports an error. With ExoPlayer's default of a few seconds, a short network drop while it loaded the next track (near the end of the current one) became a load error: ExoPlayer cut the current track off, moved to the failed one and stopped there (0:00/0:00). Downloads ahead are retried too, see [CACHING.md](CACHING.md).

A track that can't load (offline and not downloaded, or a stream breaking off) is reported on `errorStream`. `_onPlayerError()` marks the queue for reloading (the player is idle after an error) and continues at the next completely cached track (`_continueAfterError()`, which asks the cache); if there is none, playback stops on the failing track and the next `play()` loads the queue again from there. Errors while a `_playerOp()` runs are handled once it finishes. If `_jumpTo()`'s target failed, it then leaves playback to `_onPlayerError()` instead of starting it.

The player's `seek()` completes once the target is ready or has failed (the error arrives on `errorStream` first). With `just_audio`, a seek to a target that failed never completed; awaited inside a `_playerOp()`, that blocked every later operation. `_seekToItem()` still stops waiting once the player reports an error or goes idle, so a seek that never completes can't block playback again. `setAudioSources()` completes once the start item is ready and throws its own errors, and `_loadQueue()` handles them the same way.

After `stop()` or an error the player is idle, so `play()` and skips load the queue again (`_loadQueue()`) instead of seeking.

## Pausing while a track loads

While a track loads or buffers, `playbackState` is `loading`, and the play button stays usable with a spinner around it; `playWhenReady` decides between Pause and Play. Loads and skips that start playback (`_loadQueue()` with `play`, `_jumpTo()`) count themselves in `_startsInProgress` and only start the track if `_playPending` is still set when it's ready (`_startUnlessPaused()`). `pause()` clears it, `play()` during the load sets it again instead of loading anew. A track that was paused while it loaded stays paused and gets its start time on `play()`, like a restored song. A load error while paused doesn't continue at a downloaded track: playback stops on the failed one.

## Skips

- `next()` and `previous()` seek within the sequence (`_jumpTo()`). Nothing is reloaded, and a cached target plays from the cache.
- Previous restarts the current track once it has played for more than 3 s (`_restartThreshold`), and always on the first track; otherwise it goes back a track. A restart is a new play, like any other skip.
- Presses during a skip are coalesced: a skip already in progress continues to the target that later presses move (`_skipTarget`), counting from its target rather than the current track. Pressing Next three times moves three tracks, however long each takes to load; earlier versions dropped presses while a skip ran. The skip buttons stay enabled during a skip for the same reason. `_skipOperationInProgress` and `_skipTarget` are reset in a `finally` block.
- Skips within 100 ms of the previous one are ignored (`_skipDebounceMs`) as doubled events. The service does this, so UI and system controls share it.
- A skip scrobbles the current track if it passed the threshold.

There is deliberately no handling for the player pausing near the end of a track: the player keeps `playing` true while buffering and on completion, so ready and not playing only happens after `pause()`.

## Bluetooth and system controls

The plugin's Media3 `MediaSession` drives the notification, the lock screen player and Bluetooth/media button controls (`PlaybackService`, a `MediaSessionService`, hosts it; Media3 builds the notification and keeps the service in the foreground while playing). The session shows the ExoPlayer's real state and the metadata of the current queue item (`AudioSource.title` etc.), so it follows gapless transitions by itself.

- **Commands go to Dart.** The session talks to `SessionPlayer`, which forwards every command (play, pause, stop, next, previous, seek) to Dart instead of acting on the ExoPlayer. `AudioPlayerService` handles them (`_onSystemCommand()`) with the same methods as the app's own buttons, so skips are debounced, scrobbled and reload the queue after an error like any other. Only these commands are available to controllers; nobody else can change the queue.
- **Every controller gets full control** (`FullControlCallback` in `PlaylistPlayer`). By default Media3 gives untrusted controllers read access only, and it can't verify apps that package visibility hides from this one, such as launchers with a media widget (Niagara): they showed the track but their buttons did nothing. With only transport controls on offer, a controller can't do more than a Bluetooth button.
- **Artwork URLs stay private.** The session publishes each item's artwork URI to every controller (as `ART_URI` and the like in the legacy metadata, readable by any notification listener), and cover art URLs carry the Subsonic token and salt, which can be replayed. So the session only gets `voidweaver-art://<item id>`; `ArtworkLoader`, the session's bitmap loader, maps it to the real URL and controllers get the bitmap.
- **Load errors don't end the session.** The ExoPlayer is idle after every load error, also when the service recovers by continuing at a downloaded track or waits for Play to load again. An idle session would remove the notification and stop the foreground service. So `SessionPlayer` reports an idle player as ready (paused, without the error) unless playback was stopped. Only `stop()` ends the notification (`SHOW_NOTIFICATION_FOR_IDLE_PLAYER_NEVER`), and the next play brings it back.
- **One session per player.** Each `VoidweaverPlayer` (one per login) has its own session; disposing it on logout releases the session and removes the notification. `PlaybackService` stops once no session is left.
- **Media keys bypass Flutter while the app is shown.** Android gives key events to the focused window first and passes media keys to the media session only if the app leaves them unhandled. Once a text field had focus (the login form, search), the `FlutterView` keeps the view focus and claims every key, re-sending unhandled ones only within the app, so media buttons (also Bluetooth) did nothing while the app was in the foreground. `MainActivity.dispatchKeyEvent()` hands media keys to `AudioManager.dispatchMediaKeyEvent()` instead, the same path they take when the app isn't focused.
- **The Dart engine outlives the activity.** Playlist logic, scrobbling and downloads run in Dart, so `MainActivity` keeps its `FlutterEngine` in `FlutterEngineCache`. Closing the activity (Back, swiping it from the recents) leaves the engine running; a new activity attaches to it.
- **Swiped away while paused**, Media3 stops `PlaybackService`. The session stays, so media buttons still reach it, and the next play starts the service again (`PlaybackService.ensureStarted()`).
- **Playback resumes after the process has died.** A Play media button (also Bluetooth or a headset) then reaches Media3's `MediaButtonReceiver`, which starts `PlaybackService` in the foreground. Media3 needs a session for it right away, before Dart runs, so `onGetSession()` answers with a stand-in, `ResumePlayer`. It's idle until Play (so the system UI binding at boot shows no notification), then buffering with a "Resuming…" notification, and it starts the cached engine (`AppEngine`, which `MainActivity` uses too). Dart starts as usual. Once `AppState.configure()` has set up the services, it restores the queue in the background (the home screen doesn't wait for it, nor for the album list) and calls `AudioPlayerService.resumeIfRequested()`, which asks the plugin (`takeResumeRequest()`) and plays. The stand-in is released once the real player plays. If Dart answers that no resume is pending, or after 60 s, it's released anyway, e.g. when logged out or offline with nothing cached. Only Play, Play/Pause and the headset button start the app (Android 8+ requires a foreground start); other keys do nothing while it isn't running.

## Audio focus

ExoPlayer owns audio focus (`setAudioAttributes(..., handleAudioFocus = true)` in `PlaylistPlayer`). It pauses on interruptions and resumes after transient ones; while focus is lost for a moment the player reports `playing` false. It also pauses when headphones are unplugged (`setHandleAudioBecomingNoisy`).

Don't request focus anywhere else, including native code. Android treats each focus listener as a separate client. An earlier `voidweaver/audio_focus` channel in `MainActivity` pushed the player's listener down the stack, so when an interruption ended Android notified the wrong listener and playback never resumed.

## Restoring playback

`PlaybackPersistenceService` saves the queue, index and position (throttled to every 5 s while playing, and after every track change). On start, `restorePlaybackState()` loads the saved song paused. It runs while the home screen is already shown; if the user starts playback first, the restore gives up and leaves the new queue alone.

- The queue is loaded with `initialIndex` and `initialPosition` instead of a `seek()` afterwards. With a separate seek, load events reporting position 0 could arrive after the seek, so the playhead showed 0:00 while audio resumed at the saved position. `_currentPosition` is also set directly so the UI is right before the player reports anything.
- If loading fails (e.g. offline at startup), `_needsSourceReload` is set and `play()` loads the queue again at `_pendingResumePosition`. Restoring never skips ahead to a downloaded track.
- A restored song has no `_currentSongStartTime` until it's played. The first `play()` sets it, sends "now playing" and starts the downloads. Without a start time it would never be scrobbled.

## Scrobbling

A song is scrobbled once it has been heard for the minimum play time (default 2 min) or the percentage threshold (default 50%), whichever comes first. Both are configurable in Settings. What counts is the time actually listened (`_listened`), not the position: `_trackListening()` adds up the position updates while playing, and skips any update where the position moved more than the time that passed (plus a second), i.e. a seek. Otherwise seeking to the end and skipping, or letting the track finish, would scrobble it, and subsoxy would take a skip for a play. When a track completes, the rest after the last position update is counted (`_listenedToEnd()`), so a track played through reaches even a 100% threshold. A restored song counts as heard up to its restored position.

Each play is scrobbled at most once, tracked by `_currentSongScrobbled`. The flag is reset whenever a song starts (`_setCurrentTrack()`), so replaying a song (e.g. with Previous) scrobbles it again. Completion checks the flag too, so a song that passed the threshold isn't submitted a second time when it ends. A song restored at a position already past the threshold counts as scrobbled, since that happened in the previous session and the queue persisted it.

Requests go through `ScrobbleQueue`, never directly to the API. The queue:

- is stored in SharedPreferences (`scrobble_queue`) and restored on start
- sends oldest first, 100 ms apart, as soon as a request is queued and every 30 s
- keeps a submission that can't be sent (network error, HTTP error, or the server refusing the credentials) at the front and stops there, so later requests never overtake it. It's retried on the next timer tick or the next queued request, and dropped only after 7 days.
- drops a submission the server rejects for itself (a `status="failed"` response that isn't an auth error, e.g. unknown song)
- drops a "now playing" that fails, since it would be stale by the time it's retried

subsoxy uses these scrobbles to tell plays from skips, so the queue's ordering and `playedAt` timestamps matter. That's also why `scrobbleNowPlaying()` and `scrobbleSubmission()` throw on failure: the queue has to know.
