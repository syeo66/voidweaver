package red.ochsenbein.voidweaver.player;

import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.util.Log;
import androidx.annotation.Nullable;
import androidx.annotation.VisibleForTesting;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MediaMetadata;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Objects;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Consumer;

/**
 * The track that was current last, for the system's playback resumption controls. System UI shows
 * them in place of the media player once a paused player timed out (after about 10 minutes) and
 * after a reboot, and asks for the track while the app may not be running, before Dart could
 * answer. Only the title, artist and album are kept; the artwork URL carries the credentials.
 *
 * <p>The home screen widget also keeps the cover it showed for the track ({@link #saveCover}): the
 * scaled bitmap in a file, and a hash of its {@link ArtworkLoader#key}, which may be the artwork
 * URL. The file is written and read on a thread of its own ({@link #io}), one task at a time.
 */
final class RecentItem {
  private static final String TAG = "VoidweaverRecent";
  private static final String PREFS = "voidweaver_player.recent";
  private static final String ID = "id";
  private static final String TITLE = "title";
  private static final String ARTIST = "artist";
  private static final String ALBUM = "album";

  /** The {@link #coverKey} of the cover file, set once the file is complete. */
  private static final String COVER_KEY = "cover_key";

  /** The track the cover file is for: the cover shows while it's the saved track. */
  private static final String COVER_ID = "cover_id";

  @VisibleForTesting static final String COVER_FILE = "voidweaver_recent_cover.png";

  private static final ExecutorService io =
      Executors.newSingleThreadExecutor(
          runnable -> {
            Thread thread = new Thread(runnable, "voidweaver-recent-cover");
            thread.setDaemon(true);
            return thread;
          });

  /**
   * Guards {@link #generation} and the cover's prefs entries. {@link #clear} counts up the
   * generation, so a cover written or read for an earlier one is dropped rather than brought back
   * after a logout.
   */
  private static final Object lock = new Object();

  private static int generation;

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

  /** Forgets the track and its cover, when the player is disposed (logout). */
  static void clear(Context context) {
    synchronized (lock) {
      generation++;
      prefs(context).edit().clear().apply();
    }
    // After any write still queued; also what a kill during a write left behind
    File file = coverFile(context);
    io.execute(
        () -> {
          delete(file);
          delete(temporaryFile(file));
        });
  }

  /**
   * What tells covers apart on the widget and in the prefs: a hash of the {@link
   * ArtworkLoader#key}, which is the artwork URL (with the credentials) for artwork without a cache
   * key. Null for null.
   */
  @Nullable
  static String coverKey(@Nullable String artworkKey) {
    if (artworkKey == null) return null;
    try {
      byte[] digest =
          MessageDigest.getInstance("SHA-256").digest(artworkKey.getBytes(StandardCharsets.UTF_8));
      StringBuilder hex = new StringBuilder(digest.length * 2);
      for (byte b : digest) hex.append(String.format("%02x", b));
      return hex.toString();
    } catch (NoSuchAlgorithmException e) {
      // Every Android device has SHA-256
      throw new IllegalStateException(e);
    }
  }

  /**
   * The {@link #coverKey} of the saved track's cover, or null if there is none for it (none saved
   * yet, or the one saved is another track's).
   */
  @Nullable
  static String savedCoverKey(Context context) {
    SharedPreferences prefs = prefs(context);
    String id = prefs.getString(ID, null);
    if (id == null || !id.equals(prefs.getString(COVER_ID, null))) return null;
    return prefs.getString(COVER_KEY, null);
  }

  /**
   * Keeps [bitmap], the cover with [coverKey], as the cover of track [id]. If the file has that
   * cover already (the next track of an album), only the track is updated. In the background.
   */
  static void saveCover(Context context, String id, String coverKey, Bitmap bitmap) {
    Context app = context.getApplicationContext();
    int saving;
    synchronized (lock) {
      saving = generation;
    }
    io.execute(
        () -> {
          File file = coverFile(app);
          synchronized (lock) {
            if (saving != generation) return;
            SharedPreferences prefs = prefs(app);
            if (coverKey.equals(prefs.getString(COVER_KEY, null)) && file.exists()) {
              if (!id.equals(prefs.getString(COVER_ID, null))) {
                prefs.edit().putString(COVER_ID, id).apply();
              }
              return;
            }
            // Until the new file is complete, the old one isn't any track's
            prefs.edit().remove(COVER_KEY).remove(COVER_ID).apply();
          }
          if (!write(file, bitmap)) return;
          synchronized (lock) {
            if (saving != generation) {
              // Logged out meanwhile: clear() deletes it after this task, but don't rely on that
              delete(file);
              return;
            }
            prefs(app).edit().putString(COVER_KEY, coverKey).putString(COVER_ID, id).apply();
          }
        });
  }

  /**
   * Reads the saved cover with [coverKey] in the background and hands it to [onLoaded] on that
   * thread: the bitmap, or null if it isn't the saved one (any more) or can't be read. A file that
   * can't be read is forgotten.
   */
  static void loadCover(Context context, String coverKey, Consumer<Bitmap> onLoaded) {
    Context app = context.getApplicationContext();
    io.execute(
        () -> {
          int loading;
          synchronized (lock) {
            loading = generation;
            if (!coverKey.equals(savedCoverKey(app))) {
              onLoaded.accept(null);
              return;
            }
          }
          File file = coverFile(app);
          Bitmap bitmap = file.exists() ? BitmapFactory.decodeFile(file.getPath()) : null;
          if (bitmap == null) {
            Log.w(TAG, "Could not read the saved cover");
            synchronized (lock) {
              if (loading == generation) {
                prefs(app).edit().remove(COVER_KEY).remove(COVER_ID).apply();
              }
            }
          }
          onLoaded.accept(bitmap);
        });
  }

  private static File coverFile(Context context) {
    // Never backed up or moved to another device
    return new File(context.getApplicationContext().getNoBackupFilesDir(), COVER_FILE);
  }

  /** Writes [bitmap] to [file] through a temporary file, so a kill never leaves half a file. */
  private static boolean write(File file, Bitmap bitmap) {
    File temporary = temporaryFile(file);
    try (OutputStream out = new FileOutputStream(temporary)) {
      if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) {
        throw new IOException("Could not compress the cover");
      }
    } catch (IOException | RuntimeException e) {
      Log.w(TAG, "Could not save the cover", e);
      delete(temporary);
      return false;
    }
    if (!temporary.renameTo(file)) {
      Log.w(TAG, "Could not save the cover: rename failed");
      delete(temporary);
      return false;
    }
    return true;
  }

  private static File temporaryFile(File file) {
    return new File(file.getPath() + ".tmp");
  }

  private static void delete(File file) {
    if (file.exists() && !file.delete()) Log.w(TAG, "Could not delete " + file.getName());
  }

  /** Waits for the cover tasks queued so far. */
  @VisibleForTesting
  static void awaitIo() {
    try {
      io.submit(() -> {}).get();
    } catch (InterruptedException | ExecutionException e) {
      throw new IllegalStateException(e);
    }
  }

  @Nullable
  private static String string(@Nullable CharSequence value) {
    return value == null ? null : value.toString();
  }
}
