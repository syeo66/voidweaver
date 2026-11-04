package red.ochsenbein.voidweaver.player;

import android.content.Context;
import android.content.SharedPreferences;
import androidx.annotation.Nullable;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MediaMetadata;
import java.util.Objects;

/**
 * The track that was current last, for the system's playback resumption controls. System UI shows
 * them in place of the media player once a paused player timed out (after about 10 minutes) and
 * after a reboot, and asks for the track while the app may not be running, before Dart could
 * answer. Only the title, artist and album are kept; the artwork URL carries the credentials.
 */
final class RecentItem {
  private static final String PREFS = "voidweaver_player.recent";
  private static final String ID = "id";
  private static final String TITLE = "title";
  private static final String ARTIST = "artist";
  private static final String ALBUM = "album";

  private RecentItem() {}

  private static SharedPreferences prefs(Context context) {
    return context.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
  }

  /** Remembers [item] as the current track. */
  static void save(Context context, MediaItem item) {
    MediaMetadata metadata = item.mediaMetadata;
    String title = string(metadata.title);
    SharedPreferences prefs = prefs(context);
    if (Objects.equals(prefs.getString(ID, null), item.mediaId)
        && Objects.equals(prefs.getString(TITLE, null), title)) {
      return;
    }
    prefs
        .edit()
        .putString(ID, item.mediaId)
        .putString(TITLE, title)
        .putString(ARTIST, string(metadata.artist))
        .putString(ALBUM, string(metadata.albumTitle))
        .apply();
  }

  /** The track saved last, as a playable item, or null if there is none (e.g. logged out). */
  @Nullable
  static MediaItem load(Context context) {
    SharedPreferences prefs = prefs(context);
    String id = prefs.getString(ID, null);
    if (id == null) return null;
    return new MediaItem.Builder()
        .setMediaId(id)
        .setMediaMetadata(
            new MediaMetadata.Builder()
                .setTitle(prefs.getString(TITLE, null))
                .setArtist(prefs.getString(ARTIST, null))
                .setAlbumTitle(prefs.getString(ALBUM, null))
                // System UI only offers to resume a playable item
                .setIsPlayable(true)
                .setIsBrowsable(false)
                .build())
        .build();
  }

  /** Forgets the track, when the player is disposed (logout). */
  static void clear(Context context) {
    prefs(context).edit().clear().apply();
  }

  @Nullable
  private static String string(@Nullable CharSequence value) {
    return value == null ? null : value.toString();
  }
}
