package red.ochsenbein.voidweaver.player;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import android.app.Application;
import java.util.ArrayList;
import java.util.List;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.android.controller.ServiceController;
import org.robolectric.shadows.ShadowLooper;

@RunWith(RobolectricTestRunner.class)
public final class PlaybackServiceTest {
  private final Application context = RuntimeEnvironment.getApplication();

  /** Created and not destroyed yet, so a failing test doesn't leave PlaybackService.instance set. */
  private final List<ServiceController<PlaybackService>> running = new ArrayList<>();

  private PlayerSession session;

  @Before
  public void setUp() {
    session = PlayerSession.create(context, "test", new FakePlayer(3));
    PlaybackService.register(context, session.session);
  }

  @After
  public void tearDown() {
    while (!running.isEmpty()) destroy(running.get(0));
    PlaybackService.unregister(session.session);
    session.session.release();
    ShadowLooper.idleMainLooper();
  }

  private ServiceController<PlaybackService> create() {
    ServiceController<PlaybackService> service = Robolectric.buildService(PlaybackService.class);
    running.add(service);
    service.create();
    ShadowLooper.idleMainLooper();
    return service;
  }

  private void destroy(ServiceController<PlaybackService> service) {
    running.remove(service);
    service.destroy();
    ShadowLooper.idleMainLooper();
  }

  private int connectedControllers() {
    ShadowLooper.idleMainLooper();
    return session.session.getConnectedControllers().size();
  }

  /**
   * Android stops the service while the app is paused in the background (after a stop, or once
   * Media3 left the foreground), but the sessions outlive it. A stopped instance must let go of
   * them: otherwise its notification manager stays connected, and when playback starts again it
   * sends start intents that the next instance takes as stale and stops itself for, leaving
   * playback without a foreground service and notification.
   */
  @Test
  public void aStoppedServiceLetsGoOfTheSessions() {
    ServiceController<PlaybackService> first = create();
    assertEquals(1, connectedControllers()); // Media3's notification manager

    destroy(first);
    assertEquals(0, connectedControllers());
    assertTrue(first.get().getSessions().isEmpty());

    ServiceController<PlaybackService> second = create();
    assertEquals(1, connectedControllers());
    assertEquals(1, second.get().getSessions().size());
  }
}
