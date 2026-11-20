package red.ochsenbein.voidweaver.player;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.robolectric.Shadows.shadowOf;

import android.app.Application;
import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import androidx.media3.common.PlaybackException;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.HttpDataSource;
import java.io.FileNotFoundException;
import java.net.ConnectException;
import java.net.NoRouteToHostException;
import java.net.SocketTimeoutException;
import java.net.UnknownHostException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ExecutionException;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.shadows.ShadowLooper;
import org.robolectric.shadows.ShadowNetwork;
import org.robolectric.shadows.ShadowNetworkCapabilities;

/**
 * {@link CoverRetry} on its own, with a fake widget: which failures wait for a network, which
 * network counts, and how often. PlayerWidgetTest covers it with the widget and real loads.
 */
@RunWith(RobolectricTestRunner.class)
public final class CoverRetryTest {
  private static final Network WIFI = ShadowNetwork.newInstance(1);
  private static final Network MOBILE = ShadowNetwork.newInstance(2);
  private static final Exception OFFLINE = new UnknownHostException("music.example");

  private final Application context = RuntimeEnvironment.getApplication();

  /** The covers the fake widget still misses. */
  private final Set<String> missing = new HashSet<>();

  /** The covers loaded again, in order. */
  private final List<String> loads = new ArrayList<>();

  private CoverRetry retry;

  @Before
  public void setUp() {
    retry =
        new CoverRetry(
            new Handler(Looper.getMainLooper()),
            new CoverRetry.Loader() {
              @Override
              public boolean isMissing(String key) {
                return missing.contains(key);
              }

              @Override
              public void load(Context context, String key) {
                loads.add(key);
              }
            });
    setOnline(false);
  }

  @After
  public void tearDown() {
    retry.reset(context);
  }

  private ConnectivityManager connectivity() {
    return context.getSystemService(ConnectivityManager.class);
  }

  private static NetworkCapabilities validated() {
    NetworkCapabilities capabilities = ShadowNetworkCapabilities.newInstance();
    shadowOf(capabilities).addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET);
    shadowOf(capabilities).addCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
    return capabilities;
  }

  /** Whether the device has a validated network when the retry starts waiting. */
  private void setOnline(boolean online) {
    shadowOf(connectivity()).setDefaultNetworkActive(true);
    Network active = connectivity().getActiveNetwork();
    if (active == null) return;
    shadowOf(connectivity())
        .setNetworkCapabilities(
            active, online ? validated() : ShadowNetworkCapabilities.newInstance());
  }

  private List<ConnectivityManager.NetworkCallback> networkCallbacks() {
    return new ArrayList<>(shadowOf(connectivity()).getNetworkCallbacks());
  }

  /** Reports [network] as the validated default network to the one callback registered. */
  private void networkAvailable(Network network) {
    List<ConnectivityManager.NetworkCallback> callbacks = networkCallbacks();
    assertEquals(1, callbacks.size());
    callbacks.get(0).onCapabilitiesChanged(network, validated());
    ShadowLooper.idleMainLooper();
  }

  /** Cover [key] failed for the network while the widget misses it. */
  private void failed(String key) {
    missing.add(key);
    retry.failed(context, key, OFFLINE);
  }

  @Test
  public void retriesOnlyFailuresOfTheNetwork() {
    DataSpec spec = new DataSpec(Uri.parse("https://music.example/rest/getCoverArt"));
    assertTrue(CoverRetry.isNetworkFailure(new UnknownHostException("music.example")));
    assertTrue(CoverRetry.isNetworkFailure(new ConnectException("refused")));
    assertTrue(CoverRetry.isNetworkFailure(new NoRouteToHostException("no route")));
    assertTrue(CoverRetry.isNetworkFailure(new SocketTimeoutException("timeout")));
    // As Media3's data sources and the loaders' futures wrap them
    assertTrue(
        CoverRetry.isNetworkFailure(
            new ExecutionException(
                new HttpDataSource.HttpDataSourceException(
                    new UnknownHostException("music.example"),
                    spec,
                    PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
                    HttpDataSource.HttpDataSourceException.TYPE_OPEN))));

    // The server answered: a proxy's 401/403, a Subsonic error document
    assertFalse(
        CoverRetry.isNetworkFailure(
            new HttpDataSource.InvalidResponseCodeException(
                401, "Unauthorized", null, Collections.emptyMap(), spec, new byte[0])));
    assertFalse(
        CoverRetry.isNetworkFailure(new MediaCache.ErrorDocumentException("text/xml")));
    // Even if something about the network went wrong after the answer: the answer decides
    assertFalse(
        CoverRetry.isNetworkFailure(
            new HttpDataSource.InvalidResponseCodeException(
                403,
                "Forbidden",
                new SocketTimeoutException("reading the error body"),
                Collections.emptyMap(),
                spec,
                new byte[0])));
    // Neither, or not known
    assertFalse(CoverRetry.isNetworkFailure(new FileNotFoundException("art.png")));
    assertFalse(CoverRetry.isNetworkFailure(new IllegalArgumentException("Unknown artwork")));
    assertFalse(CoverRetry.isNetworkFailure(new RuntimeException("decoding failed")));
  }

  @Test
  public void loadsAgainWhenANetworkComesBack() {
    failed("a");
    assertTrue(retry.isWaiting());
    assertEquals(1, networkCallbacks().size());

    networkAvailable(WIFI);

    assertEquals(List.of("a"), loads);
    // Waits on until the cover shows, or fails again
    assertTrue(retry.isWaiting());
    retry.stop(context);
    assertTrue(networkCallbacks().isEmpty());
  }

  @Test
  public void ignoresTheNetworkThatWasThereWhenTheLoadFailed() {
    setOnline(true);
    failed("a");

    networkAvailable(WIFI);
    assertTrue(loads.isEmpty());

    networkAvailable(MOBILE);
    assertEquals(List.of("a"), loads);
  }

  @Test
  public void doesNotWaitWhenTheServerAnswered() {
    missing.add("a");
    retry.failed(context, "a", new MediaCache.ErrorDocumentException("text/xml"));

    assertFalse(retry.isWaiting());
    assertTrue(networkCallbacks().isEmpty());
  }

  @Test
  public void anAnswerFromTheServerEndsTheWait() {
    failed("a");
    networkAvailable(WIFI);

    retry.failed(context, "a", new MediaCache.ErrorDocumentException("text/xml"));

    assertFalse(retry.isWaiting());
    assertTrue(networkCallbacks().isEmpty());
  }

  @Test
  public void triesEachCoverAFewTimesAtMost() {
    failed("a");
    for (int i = 0; i < CoverRetry.MAX_RETRIES; i++) {
      networkAvailable(i % 2 == 0 ? WIFI : MOBILE);
      failed("a");
    }
    assertEquals(CoverRetry.MAX_RETRIES, loads.size());
    assertFalse(retry.isWaiting());

    // The same cover again: its tries still count
    failed("a");
    assertFalse(retry.isWaiting());

    // Another cover has tries of its own
    failed("b");
    assertTrue(retry.isWaiting());
  }

  @Test
  public void stopsWaitingForACoverNoLongerShown() {
    failed("a");

    retry.showing(context, "a");
    assertTrue(retry.isWaiting());

    retry.showing(context, null);
    assertFalse(retry.isWaiting());
    assertTrue(networkCallbacks().isEmpty());
  }

  @Test
  public void doesNotLoadACoverNoLongerMissing() {
    failed("a");
    missing.remove("a");

    networkAvailable(WIFI);

    assertTrue(loads.isEmpty());
    assertFalse(retry.isWaiting());
  }
}
