package red.ochsenbein.voidweaver.player;

import android.content.Context;
import android.graphics.Bitmap;
import android.net.Uri;
import androidx.annotation.Nullable;
import androidx.media3.common.util.BitmapLoader;
import androidx.media3.datasource.DataSourceBitmapLoader;
import androidx.media3.datasource.DefaultDataSource;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Function;

/**
 * Loads the artwork of the media session, which only sees opaque {@code voidweaver-art://<id>}
 * URIs. The session publishes the artwork URI to every controller (as {@code ART_URI} and friends
 * in the legacy metadata, which any notification listener can read), and the real URLs carry the
 * Subsonic credentials (a token and salt that can be replayed). The bitmap itself is loaded here
 * and handed to the controllers instead.
 *
 * <p>Artwork registered with a cache key is read through the {@link MediaCache}, under that key
 * (the real URL changes with every token): it shows without the network once it was loaded or
 * downloaded ahead with the upcoming tracks, and a track change doesn't fetch it again. Without a
 * key, it's loaded from the network every time.
 */
final class ArtworkLoader implements BitmapLoader {
  static final String SCHEME = "voidweaver-art";

  private final BitmapLoader upstream;
  private final Function<String, BitmapLoader> cachedLoader;
  private final Map<String, Target> targets = new ConcurrentHashMap<>();

  /** The real URL of an item's artwork, and its key in the media cache (null: not cached). */
  private static final class Target {
    final Uri uri;
    @Nullable final String cacheKey;

    Target(Uri uri, @Nullable String cacheKey) {
      this.uri = uri;
      this.cacheKey = cacheKey;
    }
  }

  /**
   * [upstream] loads artwork without a cache key, and any URI that isn't one of ours;
   * [cachedLoader] returns a loader that reads through the media cache under the given key.
   */
  ArtworkLoader(BitmapLoader upstream, Function<String, BitmapLoader> cachedLoader) {
    this.upstream = upstream;
    this.cachedLoader = cachedLoader;
  }

  /**
   * Loads with the player's HTTP settings (user agent, timeouts) and its check for error documents
   * (see {@link MediaCache.ErrorDocumentGuard}), so a Subsonic error isn't decoded, or cached, as
   * the artwork.
   */
  static ArtworkLoader create(Context context) {
    Context app = context.getApplicationContext();
    return new ArtworkLoader(
        new DataSourceBitmapLoader.Builder(app)
            .setDataSourceFactory(
                new DefaultDataSource.Factory(app, new MediaCache.ErrorDocumentGuard.Factory()))
            .build(),
        // A loader per load, with that load's key: DataSourceBitmapLoader only passes the URI on.
        // The data source is created on the loader's thread, so opening the cache doesn't block
        // the main thread.
        key ->
            new DataSourceBitmapLoader.Builder(app)
                .setDataSourceFactory(
                    () ->
                        MediaCache.dataSourceFactory(app)
                            .setCacheKeyFactory(dataSpec -> key)
                            .createDataSource())
                .build());
  }

  /**
   * The URI to give the session for the artwork [uri] of item [id], cached under [cacheKey] if it
   * isn't null.
   */
  Uri register(String id, Uri uri, @Nullable String cacheKey) {
    targets.put(id, new Target(uri, cacheKey));
    return new Uri.Builder().scheme(SCHEME).authority(id).build();
  }

  /** Forgets the URIs registered so far, when the playlist is replaced. */
  void clear() {
    targets.clear();
  }

  @Override
  public boolean supportsMimeType(String mimeType) {
    return upstream.supportsMimeType(mimeType);
  }

  @Override
  public ListenableFuture<Bitmap> decodeBitmap(byte[] data) {
    return upstream.decodeBitmap(data);
  }

  @Override
  public ListenableFuture<Bitmap> loadBitmap(Uri uri) {
    if (!SCHEME.equals(uri.getScheme())) return upstream.loadBitmap(uri);
    Target target = targets.get(uri.getAuthority());
    if (target == null) {
      return Futures.immediateFailedFuture(new IllegalArgumentException("Unknown artwork " + uri));
    }
    if (target.cacheKey == null) return upstream.loadBitmap(target.uri);
    return cachedLoader.apply(target.cacheKey).loadBitmap(target.uri);
  }
}
