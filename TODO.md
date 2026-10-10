# TODO

## Features
- [ ] Download whole albums/playlists for offline listening (upcoming tracks are already cached)
- [ ] Explicit offline mode with indicator, browsing limited to downloaded content
- [ ] Configurable audio cache size (fixed at 1 GB)
- [ ] Crossfade / gapless playback
- [ ] Equalizer
- [ ] In-app volume slider
- [ ] Album art transitions

## Reliability
- [ ] Handle self-signed certificates
- [ ] Better login validation and feedback
- [ ] Smarter background sync (currently every 5 minutes)
- [ ] Structured logging
- [ ] Crash reporting
- [ ] Battery optimization

## Architecture
- [ ] Replace SharedPreferences with SQLite for complex data

## Tests
- [ ] Integration tests for full user flows
- [ ] Playback tests beyond the mocked player
- [ ] ReplayGain volume calculation tests
