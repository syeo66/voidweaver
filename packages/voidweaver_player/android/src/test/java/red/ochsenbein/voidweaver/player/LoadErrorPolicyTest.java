package red.ochsenbein.voidweaver.player;

import static org.junit.Assert.assertEquals;

import android.net.Uri;
import androidx.media3.common.C;
import androidx.media3.common.PlaybackException;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.HttpDataSource;
import androidx.media3.exoplayer.source.LoadEventInfo;
import androidx.media3.exoplayer.source.MediaLoadData;
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy.LoadErrorInfo;
import java.io.IOException;
import java.net.SocketTimeoutException;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
public final class LoadErrorPolicyTest {
  private static final DataSpec SPEC =
      new DataSpec.Builder().setUri(Uri.parse("https://music.example.com/rest/stream")).build();

  private final LoadErrorPolicy policy = new LoadErrorPolicy();

  private static LoadErrorInfo failure(IOException error, int errorCount) {
    return new LoadErrorInfo(
        new LoadEventInfo.Builder(LoadEventInfo.getNewId(), SPEC, /* elapsedRealtimeMs= */ 0)
            .build(),
        new MediaLoadData(C.DATA_TYPE_MEDIA),
        error,
        errorCount);
  }

  @Test
  public void doesNotRetryAnErrorDocument() {
    IOException error = new MediaCache.ErrorDocumentException("application/xml");

    assertEquals(C.TIME_UNSET, policy.getRetryDelayMsFor(failure(error, 1)));
  }

  @Test
  public void doesNotRetryAWrappedErrorDocument() {
    IOException error =
        new IOException("Loading failed", new MediaCache.ErrorDocumentException("text/html"));

    assertEquals(C.TIME_UNSET, policy.getRetryDelayMsFor(failure(error, 1)));
  }

  @Test
  public void retriesNetworkErrorsWithGrowingDelays() {
    IOException[] errors = {
      new IOException("Connection reset"),
      new SocketTimeoutException("Read timed out"),
      new HttpDataSource.HttpDataSourceException(
          new IOException("Unable to connect"),
          SPEC,
          PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
          HttpDataSource.HttpDataSourceException.TYPE_OPEN),
    };
    for (IOException error : errors) {
      assertEquals(error.toString(), 0, policy.getRetryDelayMsFor(failure(error, 1)));
      assertEquals(error.toString(), 1000, policy.getRetryDelayMsFor(failure(error, 2)));
      assertEquals(error.toString(), 5000, policy.getRetryDelayMsFor(failure(error, 9)));
    }
  }

  @Test
  public void retriesALoadEightTimes() {
    assertEquals(8, policy.getMinimumLoadableRetryCount(C.DATA_TYPE_MEDIA));
  }
}
