package com.example.voidweaver.player;

import android.graphics.Bitmap;
import android.net.Uri;
import androidx.media3.common.util.BitmapLoader;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Loads the artwork of the media session, which only sees opaque {@code voidweaver-art://<id>}
 * URIs. The session publishes the artwork URI to every controller (as {@code ART_URI} and friends
 * in the legacy metadata, which any notification listener can read), and the real URLs carry the
 * Subsonic credentials (a token and salt that can be replayed). The bitmap itself is loaded here
 * and handed to the controllers instead.
 */
final class ArtworkLoader implements BitmapLoader {
  static final String SCHEME = "voidweaver-art";

  private final BitmapLoader upstream;
  private final Map<String, Uri> uris = new ConcurrentHashMap<>();

  ArtworkLoader(BitmapLoader upstream) {
    this.upstream = upstream;
  }

  /** The URI to give the session for the artwork [uri] of item [id]. */
  Uri register(String id, Uri uri) {
    uris.put(id, uri);
    return new Uri.Builder().scheme(SCHEME).authority(id).build();
  }

  /** Forgets the URIs registered so far, when the playlist is replaced. */
  void clear() {
    uris.clear();
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
    Uri target = uris.get(uri.getAuthority());
    if (target == null) {
      return Futures.immediateFailedFuture(new IllegalArgumentException("Unknown artwork " + uri));
    }
    return upstream.loadBitmap(target);
  }
}
