package red.ochsenbein.voidweaver.player;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Handler;
import android.util.Log;
import androidx.annotation.Nullable;
import androidx.annotation.VisibleForTesting;
import androidx.media3.datasource.HttpDataSource;
import java.net.SocketException;
import java.net.SocketTimeoutException;
import java.net.UnknownHostException;
import java.util.Objects;
import java.util.function.Predicate;

/**
 * Loads the home screen widget's cover again when a network comes back, after a load failed for
 * the network ({@link #failed}): up to {@link #MAX_RETRIES} times per cover. Not after the server
 * answered (an error status or document): the same request would fail the same way, and failed
 * logins add up (see "Rejected credentials" in docs/DEVELOPMENT.md).
 *
 * <p>It waits with a {@link NetworkMonitor.Callback} of its own, registered only while it waits.
 * The network that was there when the load failed doesn't count: the load just failed on it.
 *
 * <p>Everything here runs on the main thread; network events are posted to [handler].
 */
final class CoverRetry {
  private static final String TAG = "VoidweaverWidget";

  /** How often a cover is loaded again after a network failure. */
  @VisibleForTesting static final int MAX_RETRIES = 3;

  /** What the widget does when a network is back. */
  interface Loader {
    /** Whether the cover [key] is still the one shown and still missing. */
    boolean isMissing(String key);

    /** Loads the cover [key] again; a failure comes back through {@link #failed}. */
    void load(Context context, String key);
  }

  private final Handler handler;
  private final Loader loader;

  /** Which load failures are retried; the tests replace it. */
  @VisibleForTesting Predicate<Throwable> retryable = CoverRetry::isNetworkFailure;

  /** The cover that failed for the network last, and how often it was loaded again since. */
  @Nullable private String key;

  private int retries;

  /** Registered while {@link #key} waits for a network. */
  @Nullable private ConnectivityManager.NetworkCallback callback;

  /** The next network event is the network that was there on registering: none came back. */
  private boolean skipCurrentNetwork;

  CoverRetry(Handler handler, Loader loader) {
    this.handler = handler;
    this.loader = loader;
  }

  /**
   * The cover [key] couldn't be loaded ([failure]): if that was the network, it's loaded again
   * when a network is back, unless it was tried {@link #MAX_RETRIES} times already.
   */
  void failed(Context context, String key, Throwable failure) {
    if (!retryable.test(failure)) {
      if (key.equals(this.key)) stop(context);
      return;
    }
    if (!key.equals(this.key)) {
      stop(context);
      this.key = key;
      retries = 0;
    }
    if (retries >= MAX_RETRIES) {
      // Once, not on every redraw of the same cover after
      if (callback != null) Log.i(TAG, "Cover not loaded again: tried " + retries + " times");
      stop(context);
      return;
    }
    waitForNetwork(context);
  }

  /** The widget shows cover [key] now (null: none): stops waiting for any other one. */
  void showing(Context context, @Nullable String key) {
    if (!Objects.equals(this.key, key)) stop(context);
  }

  /** Unregisters the callback. The tries made for {@link #key} still count. */
  void stop(Context context) {
    if (callback == null) return;
    ConnectivityManager.NetworkCallback registered = callback;
    callback = null;
    skipCurrentNetwork = false;
    try {
      context
          .getApplicationContext()
          .getSystemService(ConnectivityManager.class)
          .unregisterNetworkCallback(registered);
    } catch (RuntimeException e) {
      Log.w(TAG, "Could not stop waiting for the network", e);
    }
  }

  @VisibleForTesting
  boolean isWaiting() {
    return callback != null;
  }

  @VisibleForTesting
  void reset(Context context) {
    stop(context);
    key = null;
    retries = 0;
    retryable = CoverRetry::isNetworkFailure;
  }

  /** Whether [failure] means the server wasn't reached: no network, no route, a timeout. */
  @VisibleForTesting
  static boolean isNetworkFailure(Throwable failure) {
    boolean network = false;
    // The loaders wrap the IOException; a few levels are enough
    Throwable cause = failure;
    for (int depth = 0; cause != null && depth < 8; depth++, cause = cause.getCause()) {
      if (cause instanceof HttpDataSource.InvalidResponseCodeException
          || cause instanceof MediaCache.ErrorDocumentException) {
        // The server answered
        return false;
      }
      if (cause instanceof UnknownHostException
          || cause instanceof SocketException // ConnectException, NoRouteToHostException, ...
          || cause instanceof SocketTimeoutException) {
        network = true;
      }
    }
    return network;
  }

  /** Registers {@link #callback}, unless it is already. */
  private void waitForNetwork(Context context) {
    if (callback != null) return;
    Context app = context.getApplicationContext();
    ConnectivityManager connectivity = app.getSystemService(ConnectivityManager.class);
    // Registering reports the network there is now, if any: it didn't come back, a load just
    // failed on it. A later one did.
    skipCurrentNetwork = isOnline(connectivity);
    ConnectivityManager.NetworkCallback[] registering = new ConnectivityManager.NetworkCallback[1];
    registering[0] =
        new NetworkMonitor.Callback(
            // On a thread of ConnectivityManager's
            () -> handler.post(() -> networkAvailable(app, registering[0])));
    callback = registering[0];
    try {
      connectivity.registerDefaultNetworkCallback(callback);
    } catch (RuntimeException e) {
      // E.g. too many callbacks registered by the app: no retry then
      Log.w(TAG, "Could not wait for the network", e);
      callback = null;
    }
  }

  private static boolean isOnline(ConnectivityManager connectivity) {
    Network network = connectivity.getActiveNetwork();
    NetworkCapabilities capabilities =
        network != null ? connectivity.getNetworkCapabilities(network) : null;
    return capabilities != null
        && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
  }

  /** A network is there: loads {@link #key} again if it's still the cover missing. */
  private void networkAvailable(Context context, ConnectivityManager.NetworkCallback from) {
    if (from != callback) return;
    if (skipCurrentNetwork) {
      skipCurrentNetwork = false;
      return;
    }
    String missing = key;
    if (missing == null || !loader.isMissing(missing)) {
      stop(context);
      return;
    }
    retries++;
    Log.i(TAG, "Network back: loading the cover again (" + retries + ")");
    loader.load(context, missing);
  }
}
