# Caching

Three caches keep the app fast and usable offline. All of them can be cleared from Settings → Cache (`AppState.clearCaches()`). Downloads that are already running still finish and land in the cache.

## API responses (`ApiCache`)

`SubsonicApi` wraps read calls in `ApiCache`, which keeps entries in memory and in SharedPreferences. Typed data is stored through `toJson`/`fromJson` codecs.

| Call | TTL | Persistent |
|------|-----|------------|
| `getAlbumList` | 3 min | yes |
| `getAlbum`, `getArtistAlbums` | 10 min | yes |
| `getArtists` | 15 min | yes |
| `search` | 5 min | yes |
| `getRandomSongs` | 1 min | no |

- **Keys** are the endpoint plus sorted query parameters, e.g. `getAlbumList2?size=500&type=recent`.
- **Deduplication**: concurrent identical calls share one request.
- **Offline fallback**: if a fetch fails, the expired entry is returned instead of the error. Expired entries are replaced but never deleted, so the last known library stays browsable offline.
- **Invalidation**: `invalidateAlbumCache()`, `invalidateArtistCache()` and `invalidateSearchCache()` clear by prefix.

`getRandomSongs` isn't persisted and expires quickly, so each shuffle gets a fresh pick from subsoxy.

## Audio files (`AudioCache`)

While a song plays, `AudioPlayerService` downloads the next 3 tracks into `audio_cache/` in the app cache directory, one at a time, nearest first.

- Cached tracks play from disk. Other tracks stream. When a download finishes, the track's stream in the player's queue is replaced with the file, see [PLAYBACK.md](PLAYBACK.md#downloads-in-the-queue).
- If a track can't be loaded and isn't cached (offline), playback skips ahead to the next cached track.
- Downloads go to a `.part` file and are renamed when complete. Non-200 responses and Subsonic error documents are discarded.
- Files are keyed by SHA-1 of server URL + song id.
- The least recently played files are evicted once the cache exceeds 1 GB.
- If the saved song can't load at startup, the queue is kept and the song is retried on the next play.

A track that wasn't prefetched (e.g. the first track of a new playlist) is streamed, so a network drop can still interrupt it.

## Cover art (`ImageCacheManager`)

Cover art URLs carry a new salt and token on every request, so every `CachedNetworkImage` passes the cover art id as `cacheKey`. Without it the disk cache would never hit. Images are limited to 800×800 on disk.
