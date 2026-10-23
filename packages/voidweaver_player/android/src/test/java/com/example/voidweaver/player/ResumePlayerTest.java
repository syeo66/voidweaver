package com.example.voidweaver.player;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import android.os.Looper;
import androidx.media3.common.Player;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.shadows.ShadowLooper;

@RunWith(RobolectricTestRunner.class)
public final class ResumePlayerTest {
  private int resumeRequests;
  private ResumePlayer player;

  @Before
  public void setUp() {
    player = new ResumePlayer(Looper.getMainLooper(), "Voidweaver", () -> resumeRequests++);
  }

  @Test
  public void isIdleUntilPlaySoItShowsNoNotification() {
    assertEquals(Player.STATE_IDLE, player.getPlaybackState());
    assertFalse(player.getPlayWhenReady());
    // A current item, so Media3 passes Play on rather than asking for playback resumption
    assertEquals(1, player.getMediaItemCount());
    assertFalse(player.isResumeRequested());
  }

  @Test
  public void playRequestsResumingOnceAndBuffers() {
    player.prepare();
    player.play();
    player.play();
    ShadowLooper.idleMainLooper();

    assertEquals(1, resumeRequests);
    assertTrue(player.isResumeRequested());
    assertTrue(player.getPlayWhenReady());
    assertEquals(Player.STATE_BUFFERING, player.getPlaybackState());
    assertEquals("Voidweaver", String.valueOf(player.getMediaMetadata().title));
  }

  @Test
  public void pauseOrStopCancelsTheRequest() {
    player.play();
    player.pause();
    ShadowLooper.idleMainLooper();
    assertFalse(player.isResumeRequested());
    assertEquals(Player.STATE_IDLE, player.getPlaybackState());

    player.play();
    player.stop();
    ShadowLooper.idleMainLooper();
    assertFalse(player.isResumeRequested());
    assertEquals(2, resumeRequests);
  }
}
