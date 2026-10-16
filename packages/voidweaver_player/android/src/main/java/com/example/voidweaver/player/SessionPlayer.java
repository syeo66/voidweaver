package com.example.voidweaver.player;

import androidx.annotation.Nullable;
import androidx.media3.common.ForwardingSimpleBasePlayer;
import androidx.media3.common.Player;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;

/**
 * The player as the media session (notification, lock screen, Bluetooth and media buttons) sees
 * it. Its state comes from the ExoPlayer, but every command is passed to Dart, where the playlist
 * logic lives (skips, scrobbling, reloading after errors), instead of acting on the ExoPlayer.
 */
final class SessionPlayer extends ForwardingSimpleBasePlayer {
  interface CommandListener {
    /** A command from the system: play, pause, stop, next, previous or seek (to [positionMs]). */
    void onCommand(String command, @Nullable Long positionMs);
  }

  private static final Player.Commands SUPPORTED_COMMANDS =
      new Player.Commands.Builder()
          .addAll(
              COMMAND_PLAY_PAUSE,
              COMMAND_STOP,
              COMMAND_SEEK_TO_NEXT,
              COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
              COMMAND_SEEK_TO_PREVIOUS,
              COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
              COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
              COMMAND_SEEK_BACK,
              COMMAND_SEEK_FORWARD,
              COMMAND_GET_CURRENT_MEDIA_ITEM,
              COMMAND_GET_TIMELINE,
              COMMAND_GET_METADATA,
              COMMAND_GET_AUDIO_ATTRIBUTES)
          .build();

  private final CommandListener listener;
  private boolean stopped = true;

  SessionPlayer(Player player, CommandListener listener) {
    super(player);
    this.listener = listener;
  }

  /**
   * Whether playback was stopped (or never started). Only then is the session shown as idle,
   * which ends the notification and the foreground service. The ExoPlayer is also idle after a
   * load error, while Dart continues at a downloaded track or waits for Play to load again.
   */
  void setStopped(boolean stopped) {
    if (this.stopped == stopped) return;
    this.stopped = stopped;
    invalidateState();
  }

  @Override
  protected State getState() {
    State state = super.getState();
    Player.Commands.Builder commands = new Player.Commands.Builder();
    for (int i = 0; i < SUPPORTED_COMMANDS.size(); i++) {
      int command = SUPPORTED_COMMANDS.get(i);
      if (state.availableCommands.contains(command)) commands.add(command);
    }
    // Previous always moves to the previous track; there is none on the first one
    if (!state.availableCommands.contains(COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)) {
      commands.remove(COMMAND_SEEK_TO_PREVIOUS);
    }
    State.Builder builder = state.buildUpon().setAvailableCommands(commands.build());
    if (state.playbackState == STATE_IDLE && !stopped && !state.timeline.isEmpty()) {
      // Paused on the failed track, see setStopped()
      builder.setPlaybackState(STATE_READY).setPlayerError(null).setIsLoading(false);
    }
    return builder.build();
  }

  @Override
  protected ListenableFuture<?> handleSetPlayWhenReady(boolean playWhenReady) {
    listener.onCommand(playWhenReady ? "play" : "pause", null);
    return Futures.immediateVoidFuture();
  }

  @Override
  protected ListenableFuture<?> handleStop() {
    listener.onCommand("stop", null);
    return Futures.immediateVoidFuture();
  }

  @Override
  protected ListenableFuture<?> handleSeek(int mediaItemIndex, long positionMs, int seekCommand) {
    switch (seekCommand) {
      case COMMAND_SEEK_TO_NEXT:
      case COMMAND_SEEK_TO_NEXT_MEDIA_ITEM:
        listener.onCommand("next", null);
        break;
      case COMMAND_SEEK_TO_PREVIOUS:
      case COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM:
        listener.onCommand("previous", null);
        break;
      case COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM:
      case COMMAND_SEEK_BACK:
      case COMMAND_SEEK_FORWARD:
        listener.onCommand("seek", Math.max(0, positionMs));
        break;
      default:
        // Not available to controllers
    }
    return Futures.immediateVoidFuture();
  }

  @Override
  protected ListenableFuture<?> handleRelease() {
    // The ExoPlayer is released by PlaylistPlayer
    return Futures.immediateVoidFuture();
  }
}
