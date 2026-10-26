package red.ochsenbein.voidweaver.player;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import android.net.Uri;
import androidx.annotation.Nullable;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.TransferListener;
import java.io.IOException;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
public final class ErrorDocumentGuardTest {
  private static final DataSpec SPEC =
      new DataSpec.Builder().setUri(Uri.parse("https://music.example.com/rest/stream")).build();

  /** Answers with the given response headers. */
  private static final class FakeHttpSource implements DataSource {
    final Map<String, List<String>> headers = new HashMap<>();
    boolean open;

    FakeHttpSource(@Nullable String headerName, String... values) {
      // HttpURLConnection reports the status line under a null key
      headers.put(null, List.of("HTTP/1.1 200 OK"));
      if (headerName != null) headers.put(headerName, List.of(values));
    }

    @Override
    public void addTransferListener(TransferListener transferListener) {}

    @Override
    public long open(DataSpec dataSpec) {
      open = true;
      return 1234;
    }

    @Override
    public int read(byte[] buffer, int offset, int length) {
      return length;
    }

    @Nullable
    @Override
    public Uri getUri() {
      return SPEC.uri;
    }

    @Override
    public Map<String, List<String>> getResponseHeaders() {
      return Collections.unmodifiableMap(headers);
    }

    @Override
    public void close() {
      open = false;
    }
  }

  @Test
  public void passesAudioThrough() throws IOException {
    FakeHttpSource upstream = new FakeHttpSource("Content-Type", "audio/mpeg");

    assertEquals(1234, new MediaCache.ErrorDocumentGuard(upstream).open(SPEC));
    assertTrue(upstream.open);
  }

  @Test
  public void passesAResponseWithoutContentTypeThrough() throws IOException {
    FakeHttpSource upstream = new FakeHttpSource(null);

    assertEquals(1234, new MediaCache.ErrorDocumentGuard(upstream).open(SPEC));
  }

  @Test
  public void failsOnASubsonicErrorDocument() {
    for (String type :
        new String[] {"text/xml; charset=utf-8", "application/xml", "application/json"}) {
      FakeHttpSource upstream = new FakeHttpSource("content-type", type);

      assertThrows(
          type, IOException.class, () -> new MediaCache.ErrorDocumentGuard(upstream).open(SPEC));
      assertFalse("closed after " + type, upstream.open);
    }
  }
}
