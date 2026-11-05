package red.ochsenbein.voidweaver.player;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.robolectric.Shadows.shadowOf;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Build;
import io.flutter.plugin.common.EventChannel;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowNetwork;
import org.robolectric.shadows.ShadowNetworkCapabilities;

@RunWith(RobolectricTestRunner.class)
// The plugin's minSdk: Robolectric would pick an older one, without registerDefaultNetworkCallback()
@Config(sdk = Build.VERSION_CODES.N)
public final class NetworkMonitorTest {
  private int available;
  private NetworkMonitor.Callback callback;

  private static final Network WIFI = ShadowNetwork.newInstance(1);
  private static final Network MOBILE = ShadowNetwork.newInstance(2);

  @Before
  public void setUp() {
    available = 0;
    callback = new NetworkMonitor.Callback(() -> available++);
  }

  private static NetworkCapabilities capabilities(boolean validated) {
    NetworkCapabilities capabilities = ShadowNetworkCapabilities.newInstance();
    shadowOf(capabilities).addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET);
    if (validated) {
      shadowOf(capabilities).addCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
    }
    return capabilities;
  }

  @Test
  public void reportsANetworkOnceItIsValidated() {
    callback.onCapabilitiesChanged(WIFI, capabilities(false));
    assertEquals(0, available);

    callback.onCapabilitiesChanged(WIFI, capabilities(true));
    assertEquals(1, available);
  }

  @Test
  public void reportsTheSameNetworkOnlyOnce() {
    // Android reports the capabilities again on every change, e.g. of the signal strength
    callback.onCapabilitiesChanged(WIFI, capabilities(true));
    callback.onCapabilitiesChanged(WIFI, capabilities(true));
    assertEquals(1, available);
  }

  @Test
  public void reportsASwitchToAnotherNetwork() {
    callback.onCapabilitiesChanged(WIFI, capabilities(true));
    callback.onCapabilitiesChanged(MOBILE, capabilities(true));
    assertEquals(2, available);
  }

  @Test
  public void reportsANetworkAgainAfterItWasLost() {
    callback.onCapabilitiesChanged(WIFI, capabilities(true));
    callback.onLost(WIFI);
    callback.onCapabilitiesChanged(WIFI, capabilities(true));
    assertEquals(2, available);
  }

  @Test
  public void reportsANetworkAgainOnceItRegainedItsConnection() {
    callback.onCapabilitiesChanged(WIFI, capabilities(true));
    // Connected, but without internet for a while
    callback.onCapabilitiesChanged(WIFI, capabilities(false));
    callback.onCapabilitiesChanged(WIFI, capabilities(true));
    assertEquals(2, available);
  }

  @Test
  public void registersWhileListenedTo() {
    Context context = RuntimeEnvironment.getApplication();
    ConnectivityManager connectivity = context.getSystemService(ConnectivityManager.class);
    NetworkMonitor monitor = new NetworkMonitor(context);
    EventChannel.EventSink sink =
        new EventChannel.EventSink() {
          @Override
          public void success(Object event) {}

          @Override
          public void error(String code, String message, Object details) {}

          @Override
          public void endOfStream() {}
        };

    monitor.onListen(null, sink);
    // Listening again replaces the callback instead of adding one
    monitor.onListen(null, sink);
    assertEquals(1, shadowOf(connectivity).getNetworkCallbacks().size());

    monitor.onCancel(null);
    assertTrue(shadowOf(connectivity).getNetworkCallbacks().isEmpty());
  }
}
