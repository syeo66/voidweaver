package com.example.voidweaver.player;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import androidx.annotation.Nullable;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import java.util.ArrayList;
import java.util.List;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.shadows.ShadowLooper;

@RunWith(RobolectricTestRunner.class)
public final class SessionPlayerTest {
  private final List<String> commands = new ArrayList<>();
  private FakePlayer exoPlayer;
  private SessionPlayer sessionPlayer;

  @Before
  public void setUp() {
    exoPlayer = new FakePlayer(3);
    sessionPlayer =
        new SessionPlayer(
            exoPlayer,
            (String command, @Nullable Long positionMs) ->
                commands.add(positionMs == null ? command : command + " " + positionMs));
    sessionPlayer.setStopped(false);
    atItem(1);
  }

  private void atItem(int index) {
    exoPlayer.setState(exoPlayer.state().buildUpon().setCurrentMediaItemIndex(index).build());
    ShadowLooper.idleMainLooper();
  }

  @Test
  public void forwardsCommandsToDartInsteadOfActing() {
    sessionPlayer.play();
    sessionPlayer.pause();
    sessionPlayer.seekToNext();
    sessionPlayer.seekToPrevious();
    sessionPlayer.seekToNextMediaItem();
    sessionPlayer.seekToPreviousMediaItem();
    sessionPlayer.seekTo(42_000);
    sessionPlayer.stop();

    assertEquals(
        List.of("play", "pause", "next", "previous", "next", "previous", "seek 42000", "stop"),
        commands);
    assertEquals(1, exoPlayer.getCurrentMediaItemIndex());
  }

  @Test
  public void offersOnlyTheSupportedCommands() {
    assertTrue(sessionPlayer.isCommandAvailable(Player.COMMAND_PLAY_PAUSE));
    assertTrue(sessionPlayer.isCommandAvailable(Player.COMMAND_SEEK_TO_NEXT));
    assertTrue(sessionPlayer.isCommandAvailable(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM));
    assertFalse(sessionPlayer.isCommandAvailable(Player.COMMAND_SET_SHUFFLE_MODE));
    assertFalse(sessionPlayer.isCommandAvailable(Player.COMMAND_SET_REPEAT_MODE));
    assertFalse(sessionPlayer.isCommandAvailable(Player.COMMAND_CHANGE_MEDIA_ITEMS));
  }

  @Test
  public void offersNoPreviousOnTheFirstTrack() {
    atItem(0);

    // Not even as "restart the track"; Previous always moves a track back
    assertFalse(sessionPlayer.isCommandAvailable(Player.COMMAND_SEEK_TO_PREVIOUS));
    assertTrue(sessionPlayer.isCommandAvailable(Player.COMMAND_SEEK_TO_NEXT));
  }

  @Test
  public void showsAPlayerIdleAfterALoadErrorAsPaused() {
    exoPlayer.setState(
        exoPlayer
            .state()
            .buildUpon()
            .setPlaybackState(Player.STATE_IDLE)
            .setPlayerError(
                new PlaybackException(
                    "offline", null, PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED))
            .build());
    ShadowLooper.idleMainLooper();

    assertEquals(Player.STATE_READY, sessionPlayer.getPlaybackState());
    assertNull(sessionPlayer.getPlayerError());
  }

  @Test
  public void showsAStoppedPlayerAsIdle() {
    exoPlayer.setState(exoPlayer.state().buildUpon().setPlaybackState(Player.STATE_IDLE).build());
    sessionPlayer.setStopped(true);
    ShadowLooper.idleMainLooper();

    assertEquals(Player.STATE_IDLE, sessionPlayer.getPlaybackState());
  }
}
