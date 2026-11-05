package red.ochsenbein.voidweaver.player;

import static org.junit.Assert.assertThrows;

import android.content.Context;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;

@RunWith(RobolectricTestRunner.class)
public final class PrefetchTest {
  // Unreachable, so a download that wasn't cancelled fails another way
  private static final String URI = "https://127.0.0.1:9/rest/stream?id=a";

  private final Context context = RuntimeEnvironment.getApplication();

  @Test
  public void cancelledWhileWaitingForItsTurn() {
    MediaCache.Prefetch prefetch = MediaCache.prefetch("server|a", URI);
    MediaCache.cancelPrefetch("server|a");

    assertThrows(MediaCache.PrefetchCancelledException.class, () -> prefetch.run(context));
  }

  @Test
  public void cancelOnlyReachesItsKey() {
    MediaCache.Prefetch prefetch = MediaCache.prefetch("server|b", URI);
    MediaCache.cancelPrefetch("server|a");

    Exception e = assertThrows(java.io.IOException.class, () -> prefetch.run(context));
    if (e instanceof MediaCache.PrefetchCancelledException) {
      throw new AssertionError("Cancelled by the key of another download");
    }
  }

  @Test
  public void aFinishedDownloadIsNoLongerCancelled() {
    MediaCache.Prefetch first = MediaCache.prefetch("server|c", URI);
    MediaCache.cancelPrefetch("server|c");
    assertThrows(MediaCache.PrefetchCancelledException.class, () -> first.run(context));

    // A new download of the same key isn't affected by the earlier cancel
    MediaCache.Prefetch second = MediaCache.prefetch("server|c", URI);
    Exception e = assertThrows(java.io.IOException.class, () -> second.run(context));
    if (e instanceof MediaCache.PrefetchCancelledException) {
      throw new AssertionError("Cancelled by an earlier cancel");
    }
  }
}
