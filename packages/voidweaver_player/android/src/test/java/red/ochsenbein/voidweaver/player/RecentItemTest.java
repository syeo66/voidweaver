package red.ochsenbein.voidweaver.player;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import android.content.Context;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MediaMetadata;
import androidx.media3.session.MediaSession;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;

@RunWith(RobolectricTestRunner.class)
public final class RecentItemTest {
  private Context context;

  @Before
  public void setUp() {
    context = RuntimeEnvironment.getApplication();
    RecentItem.clear(context);
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
