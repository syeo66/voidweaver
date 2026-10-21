# Caching

Three caches keep the app fast and usable offline. All of them can be cleared from Settings → Cache (`AppState.clearCaches()`). Downloads that are already running still finish and land in the cache.

## API responses (`ApiCache`)

`SubsonicApi` wraps read calls in `ApiCache`, which keeps entries in memory and, for persistent ones, as JSON files in `api_cache/` in the app cache directory (one file per key, named by its MD5). Typed data is stored through `toJson`/`fromJson` codecs.

Older versions kept persistent entries in SharedPreferences. On Android that's a single XML file, loaded whole at startup and rewritten whole on every change, including each playback position save, so a large library slowed both down. The first time the cache is used, those entries are moved to files (search results are dropped). Files are written to a temporary name and then renamed, and a corrupted file is deleted and fetched again.

| Call | TTL | Persistent |
|------|-----|------------|
| `getAlbumList` | 3 min | yes |
| `getAlbum`, `getArtistAlbums` | 10 min | yes |
| `getArtists` | 15 min | yes |
| `search` | 5 min | no (each query would leave an entry behind) |

- **Keys** are the endpoint plus sorted query parameters, e.g. `getAlbumList2?size=500&type=newest`. The album list is one entry holding every page (`getAlbumList2` returns at most 500 albums per request, so `getAlbumList` follows `offset` until a page comes back short).
- **Deduplication**: concurrent identical calls share one request.
- **Offline fallback**: if a fetch fails, the expired entry is returned instead of the error. Expired entries are replaced but never deleted, so the last known library stays browsable offline.
- **Versioned entries**: `getOrFetch(version: ...)` takes a cheap request for the version of the data on the server, stored with the entry. An expired entry with the same version is renewed (in memory only) instead of fetched again; a null version means unknown and fetches. The album list uses `getLibraryVersion()`, the last scan and song count from `getScanStatus`, so the 5-minute background sync costs one small request until the server scans the library. Servers that don't report `lastScan` (it's an extension, Navidrome has it) get the full fetch every time.
- **Forced refresh**: `getOrFetch(forceRefresh: true)` fetches even if the entry hasn't expired, and still falls back to it offline. Pull-to-refresh on the album list uses it (`getAlbumList(forceRefresh: true)`).
- **Clearing**: `SubsonicApi.clearCache()` (Settings, logout) removes every entry, in memory and persisted.

`getRandomSongs` isn't cached, so each shuffle gets a fresh pick from subsoxy.

## Audio files (Media3 cache)

Audio is cached by the player itself: a Media3 `SimpleCache` in `media_cache/` in the app cache directory (`MediaCache.java` in `packages/voidweaver_player`), shared by all logins. `AudioCache` (Dart) is a thin layer over it that works by song.

- **Playback reads through the cache.** Cached data plays without the network; whatever isn't cached is streamed and cached on the way. So a track that has played once (to the end) plays offline next time, as do the downloaded ones.
- **Downloads ahead.** While a song plays, `AudioPlayerService` downloads the next 3 tracks into the cache, one at a time, nearest first (`MediaCache.prefetch()`, a Media3 `CacheWriter`). An interrupted download keeps what it got, and the next attempt continues from there. A failed download is retried up to 5 times while the song plays (after 5 s, doubling up to 80 s), then the next track is downloaded. Without retries, a short network drop left the next track uncached until the next track change, so the player had to stream it at the transition, and a drop at that moment stopped playback.
- **Keys** are server URL + song id (`AudioCache.keyFor()`), set as each queue item's cache key. Stream URLs can't be the key: they carry a new salt and token on every request.
- **Error documents aren't cached.** Subsonic reports errors as HTTP 200 with an XML/JSON body; `ErrorDocumentGuard` fails such responses before they reach the cache.
- **Eviction**: least recently used, once the cache exceeds 1 GB.
- **ReplayGain** of a cached song is read from the cached start of the file (`AudioCache.readReplayGain()`), also offline.
- **Offline**: if a track can't be loaded, playback continues at the next track that's completely cached. If the saved song can't load at startup, the queue is kept and the song is retried on the next play.

A track that wasn't cached (e.g. the first track of a new playlist) is streamed, so a network drop can still interrupt it.

The Dart download cache used before (`audio_cache/`) is deleted when the Media3 cache is first opened.

## Cover art (`ImageCacheManager`)

Cover art URLs carry a new salt and token on every request, so the URL can't be the cache key; without a key the disk cache would never hit. All cover art goes through `ImageCacheManager.buildCoverArt()` / `coverArtProvider()`, which use `SubsonicApi.coverArtCacheKey()`: the server URL plus the cover art id, because ids like `al-1` repeat across servers. Don't use `CachedNetworkImage` directly. Images are limited to 800×800 on disk. Logout and Settings' clear cache empty the image cache.
