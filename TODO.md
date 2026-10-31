# TODO

## Features
- [ ] Download whole albums for offline listening (upcoming tracks are already cached)
- [ ] Explicit offline mode with indicator, browsing limited to downloaded content
- [ ] Configurable audio cache size (fixed at 1 GB, `MediaCache.MAX_BYTES`)
- [ ] Crossfade
- [ ] Equalizer
- [ ] In-app volume slider
- [ ] Album art transitions

## Reliability
- [ ] Handle self-signed certificates
- [ ] Better login validation and feedback
- [ ] Smarter background sync: "Recently added" is only fetched again after a library scan (`getScanStatus`), but "Recently played" is still fetched every 5 minutes while the app is visible
- [ ] Crash reporting
- [ ] Battery optimization

## Tests
- [ ] More integration flows: offline (cached tracks), skips during loads, playback restore after a restart
