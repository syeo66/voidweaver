package red.ochsenbein.voidweaver.player;

import android.os.Looper;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MediaMetadata;
import androidx.media3.common.Player;
import androidx.media3.common.SimpleBasePlayer;
import com.google.common.collect.ImmutableList;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;

/**
 * Stands in for the app's player while the app starts again for a media button (playback
 * resumption), see {@link PlaybackService#onGetSession}. The real player only exists once Dart
 * runs, but Media3 needs a session for the button right away, and a notification soon after.
 *
 * <p>Idle (no notification) until Play, then buffering, which shows a notification and keeps the
 * service in the foreground until the app's player plays.
 */
final class ResumePlayer extends SimpleBasePlayer {
  interface Listener {
    /** Play was pressed: start the app so it can resume. */
    void onResumeRequested();
  }

  private static final Player.Commands COMMANDS =
      new Player.Commands.Builder()
          .addAll(
              COMMAND_PLAY_PAUSE,
              COMMAND_PREPARE,
              COMMAND_STOP,
              COMMAND_GET_CURRENT_MEDIA_ITEM,
              COMMAND_GET_TIMELINE,
              COMMAND_GET_METADATA)
          .build();

  private final String title;
  private final Listener listener;
  private boolean resumeRequested;

  ResumePlayer(Looper looper, String title, Listener listener) {
    super(looper);
    this.title = title;
    this.listener = listener;
  }

  /** Whether Play was pressed and not cancelled by Pause or Stop since. */
  boolean isResumeRequested() {
    return resumeRequested;
  }

  @Override
  protected State getState() {
    MediaItem item =
        new MediaItem.Builder()
            .setMediaId("resume")
            .setMediaMetadata(
                new MediaMetadata.Builder().setTitle(title).setArtist("Resuming…").build())
            .build();
    return new State.Builder()
        .setAvailableCommands(COMMANDS)
        // A timeline is needed for a notification, and a current item for Media3 to pass Play on
        // instead of asking for playback resumption, which this player can't do itself
        .setPlaylist(ImmutableList.of(new MediaItemData.Builder("resume").setMediaItem(item).build()))
        .setPlayWhenReady(resumeRequested, PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
        .setPlaybackState(resumeRequested ? STATE_BUFFERING : STATE_IDLE)
        .build();
  }

  @Override
  protected ListenableFuture<?> handleSetPlayWhenReady(boolean playWhenReady) {
    boolean requested = playWhenReady && !resumeRequested;
    resumeRequested = playWhenReady;
    if (requested) listener.onResumeRequested();
    return Futures.immediateVoidFuture();
  }

  @Override
  protected ListenableFuture<?> handlePrepare() {
    return Futures.immediateVoidFuture();
  }

  @Override
  protected ListenableFuture<?> handleStop() {
    resumeRequested = false;
    return Futures.immediateVoidFuture();
  }

  @Override
  protected ListenableFuture<?> handleRelease() {
    return Futures.immediateVoidFuture();
  }
}
