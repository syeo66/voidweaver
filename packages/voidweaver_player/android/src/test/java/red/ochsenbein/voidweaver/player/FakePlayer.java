package red.ochsenbein.voidweaver.player;

import android.os.Looper;
import androidx.media3.common.MediaItem;
import androidx.media3.common.Player;
import androidx.media3.common.SimpleBasePlayer;
import com.google.common.collect.ImmutableList;

/**
 * A player with a playlist of items "a", "b", "c", ... whose state the test sets, standing in for
 * the ExoPlayer.
 */
final class FakePlayer extends SimpleBasePlayer {
  private State state;

  FakePlayer(int itemCount) {
    super(Looper.getMainLooper());
    ImmutableList.Builder<MediaItemData> playlist = ImmutableList.builder();
    for (int i = 0; i < itemCount; i++) {
      String id = String.valueOf((char) ('a' + i));
      playlist.add(
          new MediaItemData.Builder(id)
              .setMediaItem(new MediaItem.Builder().setMediaId(id).build())
              .setDurationUs(180_000_000)
              .build());
    }
    state =
        new State.Builder()
            .setAvailableCommands(new Player.Commands.Builder().addAllCommands().build())
            .setPlaylist(playlist.build())
            .setPlaybackState(STATE_READY)
            .build();
  }

  State state() {
    return state;
  }

  void setState(State state) {
    this.state = state;
    invalidateState();
  }

  @Override
  protected State getState() {
    // Like ExoPlayer, offers moving to another item only where there is one
    Player.Commands.Builder commands = state.availableCommands.buildUpon();
    if (state.currentMediaItemIndex <= 0) commands.remove(COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM);
    if (state.currentMediaItemIndex >= state.timeline.getWindowCount() - 1) {
      commands.remove(COMMAND_SEEK_TO_NEXT_MEDIA_ITEM);
    }
    return state.buildUpon().setAvailableCommands(commands.build()).build();
  }
}
