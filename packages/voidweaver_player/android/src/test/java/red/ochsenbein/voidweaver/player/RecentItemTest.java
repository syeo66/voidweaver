package red.ochsenbein.voidweaver.player;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Color;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.concurrent.atomic.AtomicReference;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MediaMetadata;
import androidx.media3.session.MediaSession;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.GraphicsMode;

// Real bitmaps, which the cover file is written from and read into
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@RunWith(RobolectricTestRunner.class)
public final class RecentItemTest {
  private Context context;

  @Before
  public void setUp() {
    context = RuntimeEnvironment.getApplication();
    RecentItem.clear(context);
    RecentItem.awaitIo();
  }

  // Artwork without a cache key is keyed by its URL, which carries the credentials
  private static final String ART_URL =
      "https://music.example/rest/getCoverArt?id=al-1&t=secrettoken&s=secretsalt";

  private static Bitmap bitmap(int color) {
    Bitmap bitmap = Bitmap.createBitmap(4, 3, Bitmap.Config.ARGB_8888);
    bitmap.eraseColor(color);
    return bitmap;
  }

  private File coverFile() {
    return new File(context.getNoBackupFilesDir(), RecentItem.COVER_FILE);
  }

  private Bitmap loadCover(String key) {
    AtomicReference<Bitmap> loaded = new AtomicReference<>();
    RecentItem.loadCover(context, key, loaded::set);
    RecentItem.awaitIo();
    return loaded.get();
  }

  /** Everything the cover left on disk: the prefs file and the cover file. */
  private String stored() throws Exception {
    StringBuilder all = new StringBuilder();
    // Robolectric keeps prefs in memory: their keys and values
    all.append(
        context.getSharedPreferences("voidweaver_player.recent", Context.MODE_PRIVATE).getAll());
    if (coverFile().exists()) {
      byte[] bytes = Files.readAllBytes(coverFile().toPath());
      all.append(new String(bytes, StandardCharsets.ISO_8859_1));
    }
    return all.toString();
  }

  @Test
  public void keysCoversByAHashThatHidesTheUrl() {
    String key = RecentItem.coverKey(ART_URL);
    assertEquals(64, key.length());
    assertFalse(key.contains("secret"));
    assertEquals(key, RecentItem.coverKey(ART_URL));
    assertFalse(key.equals(RecentItem.coverKey("art-al-1")));
    assertNull(RecentItem.coverKey(null));
  }

  @Test
  public void keepsTheCoverOfTheSavedTrack() throws Exception {
    RecentItem.save(context, item("1", "Dawn"));
    String key = RecentItem.coverKey(ART_URL);
    RecentItem.saveCover(context, "1", key, bitmap(Color.RED));
    RecentItem.awaitIo();

    assertEquals(key, RecentItem.savedCoverKey(context));
    Bitmap loaded = loadCover(key);
    assertNotNull(loaded);
    assertEquals(4, loaded.getWidth());
    assertEquals(Color.RED, loaded.getPixel(0, 0));
    // Neither the URL nor its credentials are stored
    String stored = stored();
    assertTrue(stored.contains(key));
    assertFalse(stored.contains("secret"));
    assertFalse(stored.contains("music.example"));
  }

  @Test
  public void savesAnOpaqueCoverAsJpeg() throws Exception {
    RecentItem.save(context, item("1", "Dawn"));
    String key = RecentItem.coverKey(ART_URL);
    Bitmap opaque = bitmap(Color.RED);
    opaque.setHasAlpha(false);
    RecentItem.saveCover(context, "1", key, opaque);
    RecentItem.awaitIo();

    byte[] bytes = Files.readAllBytes(coverFile().toPath());
    assertEquals((byte) 0xFF, bytes[0]);
    assertEquals((byte) 0xD8, bytes[1]);
    Bitmap loaded = loadCover(key);
    assertNotNull(loaded);
    assertEquals(4, loaded.getWidth());
    // Lossy: about red
    int pixel = loaded.getPixel(1, 1);
    assertTrue(Color.red(pixel) > 230 && Color.green(pixel) < 25 && Color.blue(pixel) < 25);
  }

  @Test
  public void keepsTheTransparencyOfACoverAsPng() throws Exception {
    RecentItem.save(context, item("1", "Dawn"));
    String key = RecentItem.coverKey(ART_URL);
    RecentItem.saveCover(context, "1", key, bitmap(Color.TRANSPARENT));
    RecentItem.awaitIo();

    byte[] bytes = Files.readAllBytes(coverFile().toPath());
    assertEquals((byte) 0x89, bytes[0]);
    assertEquals((byte) 'P', bytes[1]);
    Bitmap loaded = loadCover(key);
    assertNotNull(loaded);
    assertEquals(0, Color.alpha(loaded.getPixel(0, 0)));
  }

  @Test
  public void hasNoCoverForAnotherTrack() {
    RecentItem.save(context, item("1", "Dawn"));
    String key = RecentItem.coverKey("art-al-1");
    RecentItem.saveCover(context, "1", key, bitmap(Color.RED));
    RecentItem.awaitIo();

    RecentItem.save(context, item("2", "Noon"));

    assertNull(RecentItem.savedCoverKey(context));
    assertNull(loadCover(key));
  }

  @Test
  public void movesTheSameCoverToTheNextTrackWithoutWritingItAgain() {
    String key = RecentItem.coverKey("art-al-1");
    RecentItem.save(context, item("1", "Dawn"));
    RecentItem.saveCover(context, "1", key, bitmap(Color.RED));
    RecentItem.awaitIo();
    long written = coverFile().lastModified();
    assertTrue(coverFile().setLastModified(written - 60_000));

    RecentItem.save(context, item("2", "Noon"));
    RecentItem.saveCover(context, "2", key, bitmap(Color.BLUE));
    RecentItem.awaitIo();

    assertEquals(key, RecentItem.savedCoverKey(context));
    assertEquals(written - 60_000, coverFile().lastModified());
    assertEquals(Color.RED, loadCover(key).getPixel(0, 0));
  }

  @Test
  public void replacesTheCoverOfAnotherAlbum() {
    RecentItem.save(context, item("1", "Dawn"));
    RecentItem.saveCover(context, "1", RecentItem.coverKey("art-al-1"), bitmap(Color.RED));
    RecentItem.save(context, item("2", "Noon"));
    String other = RecentItem.coverKey("art-al-2");
    RecentItem.saveCover(context, "2", other, bitmap(Color.BLUE));
    RecentItem.awaitIo();

    assertEquals(other, RecentItem.savedCoverKey(context));
    assertEquals(Color.BLUE, loadCover(other).getPixel(0, 0));
  }

  @Test
  public void aLogoutDropsACoverStillBeingSaved() throws Exception {
    RecentItem.save(context, item("1", "Dawn"));
    String key = RecentItem.coverKey(ART_URL);
    // Queued, but not written before the logout
    RecentItem.saveCover(context, "1", key, bitmap(Color.RED));
    RecentItem.clear(context);
    RecentItem.awaitIo();

    assertFalse(coverFile().exists());
    RecentItem.save(context, item("1", "Dawn"));
    assertNull(RecentItem.savedCoverKey(context));
    assertNull(loadCover(key));
  }

  @Test
  public void aLogoutDeletesTheCover() throws Exception {
    RecentItem.save(context, item("1", "Dawn"));
    String key = RecentItem.coverKey("art-al-1");
    RecentItem.saveCover(context, "1", key, bitmap(Color.RED));
    RecentItem.awaitIo();
    assertTrue(coverFile().exists());
    // Left by a kill during a write
    File temporary = new File(coverFile().getPath() + ".tmp");
    assertTrue(temporary.createNewFile());

    RecentItem.clear(context);
    RecentItem.awaitIo();

    assertFalse(coverFile().exists());
    assertFalse(temporary.exists());
    assertNull(RecentItem.savedCoverKey(context));
  }

  @Test
  public void aMissingFileMeansNoCover() {
    RecentItem.save(context, item("1", "Dawn"));
    String key = RecentItem.coverKey("art-al-1");
    RecentItem.saveCover(context, "1", key, bitmap(Color.RED));
    RecentItem.awaitIo();
    // E.g. deleted by hand
    assertTrue(coverFile().delete());

    assertNull(loadCover(key));
    // Forgotten, so the widget doesn't ask again
    assertNull(RecentItem.savedCoverKey(context));

    // Saving the same cover again writes the file, rather than only moving it to the track
    RecentItem.saveCover(context, "1", key, bitmap(Color.RED));
    RecentItem.awaitIo();
    assertEquals(Color.RED, loadCover(key).getPixel(0, 0));
  }

  @Test
  public void aBrokenFileMeansNoCover() throws Exception {
    RecentItem.save(context, item("1", "Dawn"));
    String key = RecentItem.coverKey("art-al-1");
    RecentItem.saveCover(context, "1", key, bitmap(Color.RED));
    RecentItem.awaitIo();
    try (FileOutputStream out = new FileOutputStream(coverFile())) {
      out.write("not a png".getBytes(StandardCharsets.US_ASCII));
    }

    assertNull(loadCover(key));
    assertNull(RecentItem.savedCoverKey(context));
  }

  private static MediaItem item(String id, String title) {
    return new MediaItem.Builder()
        .setMediaId(id)
        .setUri("https://example.org/rest/stream?id=" + id + "&t=token&s=salt")
        .setMediaMetadata(
            new MediaMetadata.Builder()
                .setTitle(title)
                .setArtist("Aurora Test")
                .setAlbumTitle("First Light")
                .setArtworkUri(android.net.Uri.parse("voidweaver-art://" + id))
                .build())
        .build();
  }

  @Test
  public void nothingSavedMeansNoItem() {
    assertNull(RecentItem.load(context));
  }

  @Test
  public void savesTheTrackAsAPlayableItemWithoutUrls() {
    RecentItem.save(context, item("1", "Dawn"));
    RecentItem.save(context, item("2", "Noon"));

    MediaItem loaded = RecentItem.load(context);
    assertEquals("2", loaded.mediaId);
    assertEquals("Noon", loaded.mediaMetadata.title.toString());
    assertEquals("Aurora Test", loaded.mediaMetadata.artist.toString());
    assertEquals("First Light", loaded.mediaMetadata.albumTitle.toString());
    // System UI only offers to resume a playable item
    assertEquals(Boolean.TRUE, loaded.mediaMetadata.isPlayable);
    assertEquals(Boolean.FALSE, loaded.mediaMetadata.isBrowsable);
    // The stream and artwork URLs carry the credentials
    assertNull(loaded.localConfiguration);
    assertNull(loaded.mediaMetadata.artworkUri);
  }

  @Test
  public void clearForgetsTheTrack() {
    RecentItem.save(context, item("1", "Dawn"));
    RecentItem.clear(context);
    assertNull(RecentItem.load(context));
  }

  @Test
  public void resumptionControlsGetTheSavedTrack() throws Exception {
    PlayerSession.Callback callback = new PlayerSession.Callback(context);
    MediaSession.MediaItemsWithStartPosition none =
        callback.onPlaybackResumption(null, null, /* isForPlayback= */ false).get();
    assertTrue(none.mediaItems.isEmpty());

    RecentItem.save(context, item("1", "Dawn"));
    MediaSession.MediaItemsWithStartPosition recent =
        callback.onPlaybackResumption(null, null, /* isForPlayback= */ false).get();
    assertEquals(1, recent.mediaItems.size());
    assertEquals("1", recent.mediaItems.get(0).mediaId);
    assertEquals(0, recent.startIndex);
  }
}
