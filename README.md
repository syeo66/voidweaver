# Voidweaver

A Flutter music player for Android and iOS that streams from your own music server.

Voidweaver is built to run against [Navidrome](https://www.navidrome.org/) through [subsoxy](https://github.com/syeo66/subsoxy), a Subsonic API proxy that learns from your plays and skips to make shuffle smarter. It also works with any other Subsonic-compatible server, but that setup isn't the focus.

## Setup

```
Voidweaver ──HTTPS──▶ reverse proxy ──▶ subsoxy (:8080) ──▶ Navidrome (:4533)
```

1. **Navidrome**: run it as usual. Voidweaver uses Navidrome's ReplayGain data and cover art.
2. **subsoxy**: run it as a Docker container (the repo has a `Dockerfile`) next to Navidrome, with `UPSTREAM_URL` pointing at Navidrome (e.g. `http://navidrome:4533`). Keep its database on a volume so listening history survives restarts. See the [subsoxy README](https://github.com/syeo66/subsoxy) for all options.
3. **Reverse proxy**: subsoxy only serves plain HTTP and Voidweaver only connects over HTTPS, so put a reverse proxy with a valid certificate (Caddy, nginx, Traefik, …) in front of subsoxy.
4. **Voidweaver**: log in with the HTTPS URL of the reverse proxy and your Navidrome username and password.

### Why subsoxy

subsoxy answers `getRandomSongs` with weighted picks based on your listening history. Voidweaver's **Random** button calls that endpoint, so with subsoxy in the path, shuffle favors music you like and avoids recently played or skipped tracks. Voidweaver sends "now playing" and scrobble requests for every track, which is the data subsoxy uses to tell plays from skips.

## Features

- Browse albums and artists, search, and play albums or random songs
- ReplayGain normalization (track or album mode, preamp, clipping prevention, fallback gain), see [docs/REPLAYGAIN.md](docs/REPLAYGAIN.md)
- Lock screen, notification and Bluetooth media controls, with background playback
- The next 3 tracks are downloaded while you listen, so playback survives network drops; library data and cover art stay browsable offline, see [docs/CACHING.md](docs/CACHING.md)
- Gapless playback between tracks once the next one is downloaded
- Scrobbles are queued and retried, so play counts aren't lost while offline
- Configurable scrobble threshold (minimum play time or percentage, whichever comes first)
- Queue and playback position restored on restart
- Sleep timer, dark mode, landscape layouts
- Network presets (Fast/Default/Slow) and adjustable timeouts

## Building

Requires the Flutter SDK (Dart 3).

```bash
make setup           # flutter pub get
make run             # run on a connected device or emulator
make build-release   # format, analyze, test, then build a release APK
```

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the architecture and development notes.

## Troubleshooting

- **Can't log in**: the URL must start with `https://` and the certificate must be valid. Check that the reverse proxy reaches subsoxy, and subsoxy reaches Navidrome.
- **Shuffle isn't personalized**: make sure the app talks to subsoxy, not straight to Navidrome. subsoxy needs some listening history before its weighting has an effect.
- **Timeouts on slow networks**: pick the Slow preset under Settings → Network & Timeouts.
- **Volume jumps between tracks**: check that your files have ReplayGain tags, or set a fallback gain.

## Privacy

No analytics. The app only talks to the server you configure. Credentials are stored in the platform's secure storage.

## License

MIT, see [LICENSE](LICENSE).
