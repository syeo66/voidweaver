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

## Audio files (Media3 cache)

Audio is cached by the player itself: a Media3 `SimpleCache` in `media_cache/` in the app cache directory (`MediaCache.java` in `packages/voidweaver_player`), shared by all logins. `AudioCache` (Dart) is a thin layer over it that works by song.

- **Playback reads through the cache.** Cached data plays without the network; whatever isn't cached is streamed and cached on the way. So a track that has played once (to the end) plays offline next time, as do the downloaded ones.
- **Downloads ahead.** While a song plays, `AudioPlayerService` downloads the next 3 tracks into the cache, one at a time, nearest first (`MediaCache.prefetch()`, a Media3 `CacheWriter`). An interrupted download keeps what it got, and the next attempt continues from there.
- **Keys** are server URL + song id (`AudioCache.keyFor()`), set as each queue item's cache key. Stream URLs can't be the key: they carry a new salt and token on every request.
- **Error documents aren't cached.** Subsonic reports errors as HTTP 200 with an XML/JSON body; `ErrorDocumentGuard` fails such responses before they reach the cache.
- **Eviction**: least recently used, once the cache exceeds 1 GB.
- **ReplayGain** of a cached song is read from the cached start of the file (`AudioCache.readReplayGain()`), also offline.
- **Offline**: if a track can't be loaded, playback continues at the next track that's completely cached. If the saved song can't load at startup, the queue is kept and the song is retried on the next play.

A track that wasn't cached (e.g. the first track of a new playlist) is streamed, so a network drop can still interrupt it.

The Dart download cache used before (`audio_cache/`) is deleted when the Media3 cache is first opened.

## Cover art (`ImageCacheManager`)

Cover art URLs carry a new salt and token on every request, so every `CachedNetworkImage` passes the cover art id as `cacheKey`. Without it the disk cache would never hit. Images are limited to 800×800 on disk.
