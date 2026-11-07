# TODO

## Features
- [ ] Download whole albums for offline listening (upcoming tracks are already cached)
- [ ] Explicit offline mode with indicator, browsing limited to downloaded content
- [ ] Configurable audio cache size (fixed at 1 GB, `MediaCache.MAX_BYTES`)

## Reliability
- [ ] Handle self-signed certificates
- [ ] Crash reporting
- [ ] Battery: fewer wakeups while playing with the screen off
  - `PlaylistPlayer` sends a full state snapshot to Dart every 200 ms (`POSITION_UPDATE_INTERVAL_MS`) even when no UI is shown; slow it down (e.g. 1 s) while the app is hidden
  - The position is saved every 5 s through legacy `SharedPreferences`, which rewrites the whole prefs file (queue JSON included) on each save; save less often while hidden, or move the position to its own store

## Tests
- [ ] More integration flows: offline (cached tracks), skips during loads, playback restore after a restart
