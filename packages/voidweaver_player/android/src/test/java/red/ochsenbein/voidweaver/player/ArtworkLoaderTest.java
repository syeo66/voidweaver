package red.ochsenbein.voidweaver.player;

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
  // The real URLs loaded through the media cache, and the keys they were loaded under
  private final List<Uri> loadedCached = new ArrayList<>();
  private final List<String> cacheKeys = new ArrayList<>();

  /** Records the URIs it loads in [into]. */
  private static BitmapLoader recording(List<Uri> into) {
    return new BitmapLoader() {
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
        into.add(uri);
        return Futures.immediateFuture(null);
      }
    };
  }

  private final ArtworkLoader loader =
      new ArtworkLoader(
          recording(loaded),
          key -> {
            cacheKeys.add(key);
            return recording(loadedCached);
          });

  @Test
  public void givesTheSessionUrisWithoutCredentials() {
    Uri uri = loader.register("7", ART, null);

    assertEquals("voidweaver-art://7", uri.toString());
    assertFalse(uri.toString().contains("token"));
  }

  @Test
  public void loadsTheRealUrl() throws Exception {
    loader.loadBitmap(loader.register("7", ART, null)).get();

    assertEquals(List.of(ART), loaded);
  }

  @Test
  public void loadsArtworkWithACacheKeyThroughTheCacheUnderThatKey() throws Exception {
    loader.loadBitmap(loader.register("7", ART, "server|art|al-1@300")).get();

    assertEquals(List.of(ART), loadedCached);
    assertEquals(List.of("server|art|al-1@300"), cacheKeys);
    assertTrue(loaded.isEmpty());
  }

  @Test
  public void passesOtherUrisOn() throws Exception {
    Uri content = Uri.parse("content://media/art/1");

    loader.loadBitmap(content).get();

    assertEquals(List.of(content), loaded);
  }

  @Test
  public void failsForArtworkOfAReplacedPlaylist() {
    Uri uri = loader.register("7", ART, null);
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
    assertTrue(loadedCached.isEmpty());
  }
}
