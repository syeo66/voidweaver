# ReplayGain

ReplayGain adjusts playback volume so tracks play at a similar loudness. Settings live in Settings → ReplayGain and apply to the current track immediately.

| Setting | Range | Effect |
|---------|-------|--------|
| Mode | Off / Track / Album / Smart | Track evens out every song. Album keeps loudness differences within an album. Smart uses Album for a queue started from an album and Track otherwise (random songs, a single song from search). Off ignores everything below. |
| Preamp | -15 to +15 dB | Added to every track's gain |
| Prevent clipping | on/off | Lowers the gain so `peak × gain` stays ≤ 1.0 |
| Fallback gain | -15 to +15 dB | Used for tracks without ReplayGain data |

The gain is `10^((gain + preamp) / 20)`, limited by the peak when clipping prevention is on. A track without a peak value counts as already at full scale, so with clipping prevention on its gain is never above 1. It can be above 1, so quiet tracks are raised too. Each track's gain is applied to its own samples inside the player, before they're mixed to the output, so it changes exactly where the track changes, also between gapless tracks (see [PLAYBACK.md](PLAYBACK.md#replaygain-per-track)). The device volume is left alone.

Values out of range count as missing, whatever their source: gains beyond ±30 dB, peaks of 0 or less or above 10, and NaN or infinity (`SettingsService.plausibleGain` / `plausiblePeak`). Album mode then uses the track's value, and track mode the fallback gain. The debug log lists the values it ignored.

## Where the values come from

1. **Server response**: Navidrome includes ReplayGain in song entries (OpenSubsonic `<replayGain>` element or flat attributes). If present, nothing else is fetched.
2. **Downloaded file**: for prefetched tracks, tags are read from the cached file (`ReplayGainReader.readFromFile`), which also works offline.
3. **Range request**: otherwise the first 256 KB of the original file are fetched through `download`, which the server never transcodes, so the tags are still there (a transcoded `stream` can lose them). If the server refuses the download (an error status, or a Subsonic error such as Navidrome's "downloads are disabled" when `EnableDownloads` is off or the user lacks the permission), the same is read from `stream` instead (`SubsonicApi.readReplayGain`). subsoxy passes both through without counting them as plays. More is fetched if the metadata is larger (ID3v2 tag, FLAC blocks up to the Vorbis comment, MP4 `moov` atom; `ReplayGainReader.readFromUrl`). If the server ignores the Range header and sends the whole file (e.g. a transcoded stream), the metadata is read from that response and then the connection is closed, so the audio isn't downloaded. Starting the track waits for this, so it gives up after 3 seconds (both requests together) and the track plays at the fallback gain.

Supported tags:

- ID3v2.3/2.4 `TXXX` frames (MP3), in any text encoding (Latin-1, UTF-16 with or without BOM, UTF-8), also after an extended header
- Vorbis comments (FLAC, Ogg)
- APE tags
- MP4/M4A iTunes-style `ilst` tags (only when `moov` comes before the audio data)
- Opus `R128_TRACK_GAIN` / `R128_ALBUM_GAIN`, used when no `REPLAYGAIN_*` tags exist. These are Q7.8 values relative to -23 LUFS, converted with `value / 256 + 5` dB.

## Debugging

Turn on **Debug Logging** under Settings → ReplayGain Debug Log to write a log file on the device. For every track played or prefetched it records the source of the values, the parsed gains and peaks, the settings and the final multiplier. The log is capped at 5 MB and can be exported through the share sheet. Every line is passed through `redactCredentials()`, so credentials in URLs (also inside error messages) are masked, but the log still contains the server address and song titles.

If tracks have no ReplayGain data, tag the library with a tool such as `rsgain`, foobar2000 or MusicBrainz Picard, then rescan in Navidrome.
