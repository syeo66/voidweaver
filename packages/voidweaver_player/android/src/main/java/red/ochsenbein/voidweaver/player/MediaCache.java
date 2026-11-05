package red.ochsenbein.voidweaver.player;

import android.content.Context;
import android.net.Uri;
import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.database.StandaloneDatabaseProvider;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.datasource.TransferListener;
import androidx.media3.datasource.cache.CacheDataSource;
import androidx.media3.datasource.cache.CacheWriter;
import androidx.media3.datasource.cache.ContentMetadata;
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor;
import androidx.media3.datasource.cache.SimpleCache;
import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * The audio cache: one Media3 {@link SimpleCache} per process, shared by all players.
 *
 * <p>Playback reads through it, so a track that's cached plays without the network and a streamed
 * track is cached while it plays. Upcoming tracks are downloaded into it with {@link #prefetch}.
 * Entries are keyed by the item's cache key (server and song id), not by URL, because stream URLs
 * carry a new token on every request.
 */
final class MediaCache {
  private static final long MAX_BYTES = 1024L * 1024 * 1024;

  @Nullable private static SimpleCache cache;

  // For the HTTP connections of playback and downloads, set from Dart's network settings
  private static volatile int connectTimeoutMs = DefaultHttpDataSource.DEFAULT_CONNECT_TIMEOUT_MILLIS;
  private static volatile int readTimeoutMs = DefaultHttpDataSource.DEFAULT_READ_TIMEOUT_MILLIS;

  private MediaCache() {}

  static synchronized SimpleCache get(Context context) {
    if (cache == null) {
      File base = context.getApplicationContext().getCacheDir();
      cache =
          new SimpleCache(
              new File(base, "media_cache"),
              new LeastRecentlyUsedCacheEvictor(MAX_BYTES),
              new StandaloneDatabaseProvider(context.getApplicationContext()));
    }
    return cache;
  }

  /**
   * Timeouts of the HTTP connections that playback and downloads open from now on: for connecting,
   * and for waiting for data on an open connection.
   */
  static void setTimeouts(int connectMs, int readMs) {
    connectTimeoutMs = connectMs;
    readTimeoutMs = readMs;
  }

  /** Data source factory for playback: cache first, network for whatever isn't cached. */
  static CacheDataSource.Factory dataSourceFactory(Context context) {
    return new CacheDataSource.Factory()
        .setCache(get(context))
        .setUpstreamDataSourceFactory(new ErrorDocumentGuard.Factory())
        .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR);
  }

  /** Downloads [uri] completely into the cache under [key]. Blocks; call off the main thread. */
  static void prefetch(Context context, String key, String uri) throws IOException {
    CacheDataSource dataSource = dataSourceFactory(context).createDataSourceForDownloading();
    DataSpec dataSpec = new DataSpec.Builder().setUri(Uri.parse(uri)).setKey(key).build();
    new CacheWriter(dataSource, dataSpec, /* temporaryBuffer= */ null, null).cache();
  }

  /** Whether the content for [key] is completely cached. */
  static boolean isCached(Context context, String key) {
    SimpleCache cache = get(context);
    long length = ContentMetadata.getContentLength(cache.getContentMetadata(key));
    return length != C.LENGTH_UNSET && cache.isCached(key, 0, length);
  }

  /** Those of [keys] that are completely cached, in order. */
  static List<String> cachedKeys(Context context, List<String> keys) {
    List<String> cached = new ArrayList<>();
    for (String key : keys) {
      if (isCached(context, key)) cached.add(key);
    }
    return cached;
  }

  /**
   * Up to [length] bytes from the start of the cached content for [key], without the network.
   * Null if the start isn't cached. Blocks; call off the main thread.
   */
  @Nullable
  static byte[] readHead(Context context, String key, int length) {
    CacheDataSource dataSource =
        new CacheDataSource.Factory().setCache(get(context)).createDataSource();
    DataSpec dataSpec =
        new DataSpec.Builder()
            .setUri(Uri.EMPTY)
            .setKey(key)
            .setLength(length)
            .build();
    byte[] buffer = new byte[length];
    int total = 0;
    try {
      dataSource.open(dataSpec);
      while (total < length) {
        int read = dataSource.read(buffer, total, length - total);
        if (read == C.RESULT_END_OF_INPUT) break;
        total += read;
      }
    } catch (IOException e) {
      // Not cached from the start (the cache-only source can't fetch the rest)
      if (total == 0) return null;
    } finally {
      try {
        dataSource.close();
      } catch (IOException ignored) {
      }
    }
    return Arrays.copyOf(buffer, total);
  }

  static long sizeInBytes(Context context) {
    return get(context).getCacheSpace();
  }

  static void clear(Context context) {
    SimpleCache cache = get(context);
    for (String key : new ArrayList<>(cache.getKeys())) {
      cache.removeResource(key);
    }
  }

  /**
   * Fails requests that the server answers with a document instead of audio: XML or JSON, as
   * Subsonic reports errors (e.g. an unknown song) with status 200, and any text, such as a login
   * or maintenance page of a reverse proxy. Without this, the document would be cached as the
   * complete song, and count as playable offline until evicted.
   */
  static final class ErrorDocumentGuard implements DataSource {
    static final class Factory implements DataSource.Factory {
      @Override
      public DataSource createDataSource() {
        // A new HTTP factory each time, so changed timeouts apply to the next connection
        DataSource http =
            new DefaultHttpDataSource.Factory()
                .setUserAgent("voidweaver")
                .setAllowCrossProtocolRedirects(true)
                .setConnectTimeoutMs(connectTimeoutMs)
                .setReadTimeoutMs(readTimeoutMs)
                .createDataSource();
        return new ErrorDocumentGuard(http);
      }
    }

    private final DataSource upstream;

    ErrorDocumentGuard(DataSource upstream) {
      this.upstream = upstream;
    }

    @Override
    public void addTransferListener(TransferListener transferListener) {
      upstream.addTransferListener(transferListener);
    }

    @Override
    public long open(DataSpec dataSpec) throws IOException {
      long length = upstream.open(dataSpec);
      for (Map.Entry<String, List<String>> header : upstream.getResponseHeaders().entrySet()) {
        if (header.getKey() == null || !header.getKey().equalsIgnoreCase("Content-Type")) continue;
        for (String value : header.getValue()) {
          if (isDocument(value)) {
            upstream.close();
            throw new IOException("Server returned a document (" + value + ") instead of audio");
          }
        }
      }
      return length;
    }

    /**
     * Whether [contentType] is a document rather than audio. Not a list of audio types, which would
     * fail audio a server reports under a type nobody thought of (application/octet-stream, ...).
     */
    static boolean isDocument(String contentType) {
      String type = contentType.trim().toLowerCase(Locale.ROOT);
      return type.startsWith("text/") || type.contains("xml") || type.contains("json");
    }

    @Override
    public int read(byte[] buffer, int offset, int length) throws IOException {
      return upstream.read(buffer, offset, length);
    }

    @Nullable
    @Override
    public Uri getUri() {
      return upstream.getUri();
    }

    @Override
    public Map<String, List<String>> getResponseHeaders() {
      return upstream.getResponseHeaders();
    }

    @Override
    public void close() throws IOException {
      upstream.close();
    }
  }
}
