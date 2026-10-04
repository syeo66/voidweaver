# ReplayGain

ReplayGain adjusts playback volume so tracks play at a similar loudness. Settings live in Settings → ReplayGain and apply to the current track immediately.

| Setting | Range | Effect |
|---------|-------|--------|
| Mode | Off / Track / Album | Track evens out every song. Album keeps loudness differences within an album. Off ignores everything below. |
| Preamp | -15 to +15 dB | Added to every track's gain |
| Prevent clipping | on/off | Lowers the gain so `peak × gain` stays ≤ 1.0 |
| Fallback gain | -15 to +15 dB | Used for tracks without ReplayGain data |

Volume is `10^((gain + preamp) / 20)`, clamped by the peak when clipping prevention is on. It is applied before playback starts, so there's no audible jump.

## Where the values come from

1. **Server response**: Navidrome includes ReplayGain in song entries (OpenSubsonic `<replayGain>` element or flat attributes). If present, nothing else is fetched.
2. **Downloaded file**: for prefetched tracks, tags are read from the cached file (`ReplayGainReader.readFromFile`), which also works offline.
3. **Range request**: otherwise the first 256 KB of the stream are fetched, plus more if the tag header is larger (`ReplayGainReader.readFromUrl`).

Supported tags:

- ID3v2.3/2.4 `TXXX` frames (MP3)
- Vorbis comments (FLAC, Ogg)
- APE tags
- MP4/M4A iTunes-style `ilst` tags (only when `moov` comes before the audio data)
- Opus `R128_TRACK_GAIN` / `R128_ALBUM_GAIN`, used when no `REPLAYGAIN_*` tags exist. These are Q7.8 values relative to -23 LUFS, converted with `value / 256 + 5` dB.

## Debugging

Turn on **Debug Logging** under Settings → ReplayGain Debug Log to write a log file on the device. For every track played or prefetched it records the source of the values, the parsed gains and peaks, the settings and the final multiplier. The log is capped at 5 MB and can be exported through the share sheet. Credentials are redacted from URLs, but the log still contains the server address and song titles.

If tracks have no ReplayGain data, tag the library with a tool such as `rsgain`, foobar2000 or MusicBrainz Picard, then rescan in Navidrome.
