package com.example.voidweaver.player;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import android.graphics.Bitmap;
import android.net.Uri;
import androidx.media3.common.util.BitmapLoader;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutionException;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
public final class ArtworkLoaderTest {
  private static final Uri ART =
      Uri.parse("https://music.example/rest/getCoverArt?id=al-1&u=me&t=token&s=salt");

  private final List<Uri> loaded = new ArrayList<>();
  private final ArtworkLoader loader =
      new ArtworkLoader(
          new BitmapLoader() {
            @Override
            public boolean supportsMimeType(String mimeType) {
              return true;
            }

            @Override
            public ListenableFuture<Bitmap> decodeBitmap(byte[] data) {
              return Futures.immediateFuture(null);
            }

            @Override
            public ListenableFuture<Bitmap> loadBitmap(Uri uri) {
              loaded.add(uri);
              return Futures.immediateFuture(null);
            }
          });

  @Test
  public void givesTheSessionUrisWithoutCredentials() {
    Uri uri = loader.register("7", ART);

    assertEquals("voidweaver-art://7", uri.toString());
    assertFalse(uri.toString().contains("token"));
  }

  @Test
  public void loadsTheRealUrl() throws Exception {
    loader.loadBitmap(loader.register("7", ART)).get();

    assertEquals(List.of(ART), loaded);
  }

  @Test
  public void failsForArtworkOfAReplacedPlaylist() {
    Uri uri = loader.register("7", ART);
    loader.clear();

    ListenableFuture<Bitmap> result = loader.loadBitmap(uri);

    assertTrue(result.isDone());
    try {
      result.get();
      throw new AssertionError("Expected a failure");
    } catch (ExecutionException | InterruptedException expected) {
      // Expected
    }
    assertTrue(loaded.isEmpty());
  }
}
