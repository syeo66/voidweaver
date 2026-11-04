package red.ochsenbein.voidweaver.player;

import android.app.PendingIntent;
import android.content.Context;
import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MediaMetadata;
import androidx.media3.common.Player;
import androidx.media3.datasource.DataSourceBitmapLoader;
import androidx.media3.session.CacheBitmapLoader;
import androidx.media3.session.LibraryResult;
import androidx.media3.session.MediaLibraryService.LibraryParams;
import androidx.media3.session.MediaLibraryService.MediaLibrarySession;
import androidx.media3.session.MediaSession;
import com.google.common.collect.ImmutableList;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;

/**
 * A media session with the artwork loader it was built with. Both the app's players and the
 * stand-in for playback resumption ({@link ResumePlayer}) get theirs here, so the app's player can
 * take over the stand-in's session (see {@link PlaybackService#claimResumeSession}).
 *
 * <p>It's a library session because {@link PlaybackService} is a {@code MediaLibraryService}: System
 * UI only offers to resume an app that answers its request for the recent item. There is nothing to
 * browse otherwise.
 */
final class PlayerSession {
  private static final String ROOT_ID = "root";

  final MediaLibrarySession session;
  final ArtworkLoader artwork;

  private PlayerSession(MediaLibrarySession session, ArtworkLoader artwork) {
    this.session = session;
    this.artwork = artwork;
  }

  static PlayerSession create(Context context, String id, Player player) {
    ArtworkLoader artwork = new ArtworkLoader(new DataSourceBitmapLoader.Builder(context).build());
    MediaLibrarySession.Builder builder =
        new MediaLibrarySession.Builder(context, player, new Callback(context))
            .setId(id)
            // As the session's default, but resolving the URIs that hide the credentials
            .setBitmapLoader(new CacheBitmapLoader(artwork));
    PendingIntent sessionActivity = PlaybackService.sessionActivity(context);
    if (sessionActivity != null) builder.setSessionActivity(sessionActivity);
    return new PlayerSession(builder.build(), artwork);
  }

  /**
   * Gives every controller full control. Media3 only does that for controllers it trusts, and to
   * check, it looks the controller's package up, which fails for apps this one can't see (package
   * visibility). Launchers with media widgets (e.g. Niagara) then only get read access: they show
   * the track, but their buttons do nothing. SessionPlayer only offers transport controls, which
   * are passed to Dart, so no controller can do more than a Bluetooth button.
   *
   * <p>The library commands include System UI's request for the recent item (playback resumption).
   * The library itself is empty.
   */
  static final class Callback implements MediaLibrarySession.Callback {
    private final Context context;

    Callback(Context context) {
      this.context = context.getApplicationContext();
    }

    @Override
    public ListenableFuture<MediaSession.ConnectionResult> onConnectAsync(
        MediaSession session, MediaSession.ControllerInfo controller) {
      return Futures.immediateFuture(
          new MediaSession.ConnectionResult.AcceptedResultBuilder(session)
              .setAvailablePlayerCommands(MediaSession.ConnectionResult.DEFAULT_PLAYER_COMMANDS)
              .setAvailableSessionCommands(
                  MediaSession.ConnectionResult.DEFAULT_SESSION_AND_LIBRARY_COMMANDS)
              .build());
    }

    /** An empty root, so other browsers still connect as they did to a plain session service. */
    @Override
    public ListenableFuture<LibraryResult<MediaItem>> onGetLibraryRoot(
        MediaLibrarySession session,
        MediaSession.ControllerInfo browser,
        @Nullable LibraryParams params) {
      MediaItem root =
          new MediaItem.Builder()
              .setMediaId(ROOT_ID)
              .setMediaMetadata(
                  new MediaMetadata.Builder().setIsBrowsable(true).setIsPlayable(false).build())
              .build();
      return Futures.immediateFuture(LibraryResult.ofItem(root, params));
    }

    @Override
    public ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> onGetChildren(
        MediaLibrarySession session,
        MediaSession.ControllerInfo browser,
        String parentId,
        int page,
        int pageSize,
        @Nullable LibraryParams params) {
      return Futures.immediateFuture(LibraryResult.ofItemList(ImmutableList.of(), params));
    }

    /**
     * The track for System UI's resumption controls (isForPlayback false), asked while the player
     * is idle: after a reboot, or while the app isn't playing. Playing never asks: both players
     * always have a current item and can't be given a playlist, so Play goes to them (and on to
     * Dart, or to the stand-in, which starts the app).
     */
    @Override
    public ListenableFuture<MediaSession.MediaItemsWithStartPosition> onPlaybackResumption(
        MediaSession mediaSession, MediaSession.ControllerInfo controller, boolean isForPlayback) {
      if (isForPlayback) {
        return Futures.immediateFailedFuture(new UnsupportedOperationException());
      }
      MediaItem item = RecentItem.load(context);
      return Futures.immediateFuture(
          new MediaSession.MediaItemsWithStartPosition(
              item == null ? ImmutableList.of() : ImmutableList.of(item), 0, C.TIME_UNSET));
    }
  }
}
