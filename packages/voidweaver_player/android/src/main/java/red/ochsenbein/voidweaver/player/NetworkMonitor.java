package red.ochsenbein.voidweaver.player;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Handler;
import android.os.Looper;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import io.flutter.plugin.common.EventChannel;

/**
 * Sends an event to Dart whenever the device's default network has a working internet connection
 * (Android validated it): when one connects, when the default switches to another one (Wi-Fi to
 * mobile data), and when one that had lost its connection has it again. Also once on listening, if
 * there is one then. Dart uses it to retry downloads that failed while offline.
 */
final class NetworkMonitor implements EventChannel.StreamHandler {
  private final ConnectivityManager connectivity;
  private final Handler mainHandler = new Handler(Looper.getMainLooper());
  @Nullable private ConnectivityManager.NetworkCallback callback;

  NetworkMonitor(Context context) {
    connectivity = context.getSystemService(ConnectivityManager.class);
  }

  @Override
  public void onListen(Object arguments, EventChannel.EventSink events) {
    onCancel(null);
    callback = new Callback(() -> mainHandler.post(() -> events.success(null)));
    connectivity.registerDefaultNetworkCallback(callback);
  }

  @Override
  public void onCancel(Object arguments) {
    if (callback == null) return;
    connectivity.unregisterNetworkCallback(callback);
    callback = null;
  }

  /**
   * Calls [onAvailable] once per default network that is validated, and again after it lost and
   * regained validation. Android reports the capabilities on every change (signal strength, ...),
   * so most reports are repeats.
   */
  static final class Callback extends ConnectivityManager.NetworkCallback {
    private final Runnable onAvailable;
    // The network last reported as available. The callbacks run one at a time, on a thread of
    // ConnectivityManager's.
    @Nullable private Network validated;

    Callback(Runnable onAvailable) {
      this.onAvailable = onAvailable;
    }

    @Override
    public void onCapabilitiesChanged(
        @NonNull Network network, @NonNull NetworkCapabilities capabilities) {
      if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) {
        if (network.equals(validated)) validated = null;
        return;
      }
      if (network.equals(validated)) return;
      validated = network;
      onAvailable.run();
    }

    @Override
    public void onLost(@NonNull Network network) {
      if (network.equals(validated)) validated = null;
    }
  }
}
