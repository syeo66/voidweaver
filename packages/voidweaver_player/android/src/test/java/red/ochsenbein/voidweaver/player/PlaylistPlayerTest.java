package red.ochsenbein.voidweaver.player;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.robolectric.Shadows.shadowOf;

import android.app.Application;
import android.os.Looper;
import androidx.annotation.Nullable;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMethodCodec;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.function.BooleanSupplier;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.shadows.ShadowLog;

/**
 * {@link PlaylistPlayer} with a real ExoPlayer, driven through its method channel like Dart does,
 * playing from a local HTTP server. The Dart side's tests use a fake player that follows the
 * replies described in {@code PlaylistPlayer}'s class doc; these check that the real one does.
 */
@RunWith(RobolectricTestRunner.class)
public final class PlaylistPlayerTest {
  /** Matches ProcessingState in Dart. */
  private static final int IDLE = 0;

  private static final int READY = 3;

  private final Application context = RuntimeEnvironment.getApplication();
  private final RecordingMessenger messenger = new RecordingMessenger();
  /** Released at the end, so a download that's waiting doesn't keep the server's thread. */
  private final CountDownLatch release = new CountDownLatch(1);

  private ServerSocket server;
  private PlaylistPlayer player;

  @Before
  public void setUp() throws IOException {
    server = new ServerSocket(0, 50, InetAddress.getLoopbackAddress());
    Thread acceptor = new Thread(this::acceptConnections, "test-server");
    acceptor.setDaemon(true);
    acceptor.start();
    player = new PlaylistPlayer(context, messenger, "test");
  }

  @After
  public void tearDown() {
    release.countDown();
    if (player != null) player.release();
    shadowOf(Looper.getMainLooper()).idle();
    try {
      server.close();
    } catch (IOException e) {
      // Closing is all that's left to do
    }
  }

  // ---- loading

  @Test
  public void aLoadRepliesOnceTheStartItemIsReady() throws Exception {
    Reply reply = load(0, audio("a"), audio("b"));
    await(reply);

    Map<?, ?> state = reply.state();
    assertEquals(READY, state.get("processingState"));
    assertEquals(0, state.get("index"));
    assertEquals(Boolean.FALSE, state.get("playing"));
    assertNotNull(state.get("duration"));
  }

  @Test
  public void aLoadStartsAtTheInitialIndexAndPosition() throws Exception {
    Reply reply =
        call(
            "setAudioSources",
            "sources",
            sources(audio("a"), audio("b")),
            "initialIndex",
            1,
            "initialPosition",
            400);
    await(reply);

    Map<?, ?> state = reply.state();
    assertEquals(READY, state.get("processingState"));
    assertEquals(1, state.get("index"));
    assertTrue(((Number) state.get("position")).longValue() >= 400);
  }

  @Test
  public void aLoadOfAnItemThatFailsRepliesWithTheError() throws Exception {
    Reply reply = load(0, url("/error"));
    await(reply);

    assertEquals("error", reply.errorCode);
    // The same error reaches Dart's listener, with the playlist index of the item that failed
    Map<?, ?> error = messenger.lastEvent("error");
    assertNotNull(error);
    assertEquals(0, error.get("index"));
  }

  @Test
  public void aLoadReplacedByAnotherIsInterrupted() throws Exception {
    Reply first = load(0, audio("slow-a"));
    settle();
    assertFalse("The load of a slow item has replied", first.done());

    Reply second = load(0, audio("b"));
    await(second);

    assertEquals("interrupted", first.errorCode);
    assertEquals(READY, second.state().get("processingState"));
  }

  @Test
  public void stopInterruptsALoad() throws Exception {
    Reply load = load(0, audio("slow-a"));
    settle();
    assertFalse(load.done());

    Reply stop = call("stop");

    assertTrue("stop() replies at once", stop.done());
    assertEquals(IDLE, stop.state().get("processingState"));
    assertEquals("interrupted", load.errorCode);
  }

  // ---- seeking

  @Test
  public void aSeekRepliesOnceTheTargetIsReady() throws Exception {
    await(load(0, audio("a")));

    Reply seek = call("seek", "position", 500);
    await(seek);

    Map<?, ?> state = seek.state();
    assertEquals(READY, state.get("processingState"));
    assertTrue(((Number) state.get("position")).longValue() >= 500);
  }

  @Test
  public void aSeekToAnotherItemRepliesOnceThatItemIsReady() throws Exception {
    await(load(0, audio("a"), audio("b")));

    Reply seek = call("seek", "index", 1, "position", 0);
    await(seek);

    assertEquals(READY, seek.state().get("processingState"));
    assertEquals(1, seek.state().get("index"));
  }

  @Test
  public void aSeekReplacedByAnotherRepliesToo() throws Exception {
    await(load(0, audio("a"), audio("slow-b")));

    Reply toSlow = call("seek", "index", 1, "position", 0);
    settle();
    assertFalse("The seek to a slow item has replied", toSlow.done());

    Reply back = call("seek", "index", 0, "position", 0);
    await(back);

    // Not an error: Dart applies the snapshot like any other reply
    assertTrue(toSlow.done());
    assertNull(toSlow.errorCode);
    assertEquals(0, back.state().get("index"));
  }

  @Test
  public void stopCompletesASeek() throws Exception {
    await(load(0, audio("a"), audio("slow-b")));
    Reply toSlow = call("seek", "index", 1, "position", 0);
    settle();
    assertFalse(toSlow.done());

    call("stop");

    assertTrue(toSlow.done());
    assertNull(toSlow.errorCode);
  }

  // ---- the other calls

  @Test
  public void everyOtherCallRepliesAtOnceWithTheState() throws Exception {
    await(load(0, audio("a")));

    Reply play = call("play");
    assertTrue(play.done());
    assertEquals(Boolean.TRUE, play.state().get("playing"));

    Reply pause = call("pause");
    assertTrue(pause.done());
    assertEquals(Boolean.FALSE, pause.state().get("playing"));

    for (Reply reply :
        Arrays.asList(
            call("setGain", "id", "a", "gain", 0.5),
            call("setVolume", "volume", 0.25),
            call("setPositionUpdateInterval", "interval", 1000))) {
      assertTrue(reply.done());
      assertEquals("state", reply.state().get("type"));
    }
  }

  @Test
  public void anUnknownCallIsNotImplemented() {
    Reply reply = call("rewind");
    assertEquals("notImplemented", reply.errorCode);
  }

  // ---- helpers

  private Reply load(int index, String... uris) {
    return call("setAudioSources", "sources", sources(uris), "initialIndex", index);
  }

  private Reply call(String method, Object... keysAndValues) {
    Map<String, Object> args = new HashMap<>();
    for (int i = 0; i < keysAndValues.length; i += 2) {
      args.put((String) keysAndValues[i], keysAndValues[i + 1]);
    }
    Reply reply = new Reply();
    player.onMethodCall(new MethodCall(method, args), reply);
    return reply;
  }

  private String url(String path) {
    return "http://127.0.0.1:" + server.getLocalPort() + path;
  }

  /** An item of the server's audio; names starting with "slow" are answered once released. */
  private String audio(String name) {
    return url("/audio/" + name + ".wav");
  }

  private static List<Map<String, Object>> sources(String... uris) {
    List<Map<String, Object>> sources = new ArrayList<>();
    for (String uri : uris) {
      Map<String, Object> source = new HashMap<>();
      source.put("id", uri);
      source.put("uri", uri);
      source.put("title", "Title");
      source.put("artist", "Artist");
      source.put("album", "Album");
      source.put("gain", 1.0);
      sources.add(source);
    }
    return sources;
  }

  private List<Map<String, Object>> sources(Object... uris) {
    return sources(Arrays.copyOf(uris, uris.length, String[].class));
  }

  /** Runs the main looper, waiting for the playback and loading threads, until [done]. */
  private void awaitUntil(BooleanSupplier done, String what) throws InterruptedException {
    long deadline = System.currentTimeMillis() + 20_000;
    while (!done.getAsBoolean() && System.currentTimeMillis() < deadline) {
      tick();
    }
    if (!done.getAsBoolean()) {
      StringBuilder log = new StringBuilder();
      for (ShadowLog.LogItem item : ShadowLog.getLogs()) {
        log.append("\n").append(item.tag).append(": ").append(item.msg);
        if (item.throwable != null) log.append(" ").append(item.throwable);
      }
      throw new AssertionError("Timed out waiting for " + what + log);
    }
  }

  private void await(Reply reply) throws InterruptedException {
    awaitUntil(reply::done, "a reply");
  }

  /** Gives what's running time to reply, for checks that something has not. */
  private void settle() throws InterruptedException {
    for (int i = 0; i < 30; i++) {
      tick();
    }
  }

  /**
   * Robolectric's clock only moves when told to, and the player's thread schedules its work
   * against it: the clock moves a little, and the real threads (loading, playback) get a moment.
   */
  private void tick() throws InterruptedException {
    shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(10));
    Thread.sleep(5);
  }

  private void awaitRelease() {
    try {
      release.await();
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
    }
  }

  /** The audio, 8 kHz 16 bit mono, one second of silence, in a WAV file. */
  private static byte[] wav() {
    int bytes = 16_000;
    ByteBuffer b = ByteBuffer.allocate(44 + bytes).order(ByteOrder.LITTLE_ENDIAN);
    b.put("RIFF".getBytes(StandardCharsets.US_ASCII)).putInt(36 + bytes);
    b.put("WAVE".getBytes(StandardCharsets.US_ASCII));
    b.put("fmt ".getBytes(StandardCharsets.US_ASCII)).putInt(16);
    b.putShort((short) 1).putShort((short) 1).putInt(8000).putInt(16_000);
    b.putShort((short) 2).putShort((short) 16);
    b.put("data".getBytes(StandardCharsets.US_ASCII)).putInt(bytes);
    return b.array();
  }

  private void acceptConnections() {
    byte[] audio = wav();
    while (!server.isClosed()) {
      try {
        Socket socket = server.accept();
        // Each on its own thread, so a download that's waiting doesn't hold up the others
        Thread connection = new Thread(() -> answer(socket, audio), "test-server-connection");
        connection.setDaemon(true);
        connection.start();
      } catch (IOException e) {
        return;
      }
    }
  }

  /** Answers one request: the audio (or the part a Range header asks for), or an error document. */
  private void answer(Socket socket, byte[] audio) {
    try (Socket s = socket) {
      BufferedReader in =
          new BufferedReader(
              new InputStreamReader(s.getInputStream(), StandardCharsets.US_ASCII));
      String path = in.readLine().split(" ")[1];
      int start = 0;
      boolean partial = false;
      for (String line = in.readLine(); line != null && !line.isEmpty(); line = in.readLine()) {
        if (line.toLowerCase().startsWith("range: bytes=")) {
          start = Integer.parseInt(line.substring("range: bytes=".length()).split("-")[0].trim());
          partial = true;
        }
      }
      OutputStream out = s.getOutputStream();
      if (path.startsWith("/error")) {
        // What Subsonic servers answer with, as HTTP 200, for a wrong password or unknown song
        byte[] body = "<error/>".getBytes(StandardCharsets.UTF_8);
        out.write(
            ("HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: "
                    + body.length
                    + "\r\nConnection: close\r\n\r\n")
                .getBytes(StandardCharsets.US_ASCII));
        out.write(body);
        return;
      }
      if (path.startsWith("/audio/slow")) awaitRelease();
      String head =
          partial
              ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes "
                  + start
                  + "-"
                  + (audio.length - 1)
                  + "/"
                  + audio.length
                  + "\r\n"
              : "HTTP/1.1 200 OK\r\n";
      String headers =
          "Content-Type: audio/wav\r\nAccept-Ranges: bytes\r\nContent-Length: "
              + (audio.length - start)
              + "\r\nConnection: close\r\n\r\n";
      out.write((head + headers).getBytes(StandardCharsets.US_ASCII));
      out.write(audio, start, audio.length - start);
      out.flush();
    } catch (IOException | RuntimeException e) {
      // The player closed the connection, or the test is over
    }
  }

  private static final class Reply implements MethodChannel.Result {
    @Nullable Object value;
    @Nullable String errorCode;
    private boolean done;

    boolean done() {
      return done;
    }

    Map<?, ?> state() {
      assertNull("Replied with an error: " + errorCode, errorCode);
      assertTrue("No reply", done);
      return (Map<?, ?>) value;
    }

    @Override
    public void success(@Nullable Object result) {
      assertFalse("Replied twice", done);
      value = result;
      done = true;
    }

    @Override
    public void error(String code, @Nullable String message, @Nullable Object details) {
      assertFalse("Replied twice", done);
      errorCode = code;
      done = true;
    }

    @Override
    public void notImplemented() {
      assertFalse("Replied twice", done);
      errorCode = "notImplemented";
      done = true;
    }
  }

  /** The Flutter engine's side of the channels: keeps the handlers, and what the player sends. */
  private static final class RecordingMessenger implements BinaryMessenger {
    private final Map<String, BinaryMessageHandler> handlers = new HashMap<>();
    private final List<Object> events = new ArrayList<>();
    private boolean listening;

    @Override
    public void send(String channel, @Nullable ByteBuffer message) {
      send(channel, message, null);
    }

    @Override
    public void send(String channel, @Nullable ByteBuffer message, @Nullable BinaryReply reply) {
      if (message == null || !channel.endsWith("/events")) return;
      message.rewind();
      events.add(StandardMethodCodec.INSTANCE.decodeEnvelope(message));
    }

    @Override
    public void setMessageHandler(String channel, @Nullable BinaryMessageHandler handler) {
      if (handler == null) {
        handlers.remove(channel);
        return;
      }
      handlers.put(channel, handler);
      if (channel.endsWith("/events") && !listening) {
        // What Dart's listen does: the player starts sending events to it
        listening = true;
        ByteBuffer listen =
            StandardMethodCodec.INSTANCE.encodeMethodCall(new MethodCall("listen", null));
        listen.flip();
        handler.onMessage(listen, reply -> {});
      }
    }

    /** The last event of [type] the player sent, or null. */
    @Nullable
    Map<?, ?> lastEvent(String type) {
      for (int i = events.size() - 1; i >= 0; i--) {
        // The envelope's decoded event
        Object event = events.get(i);
        if (event instanceof Map && type.equals(((Map<?, ?>) event).get("type"))) {
          return (Map<?, ?>) event;
        }
      }
      return null;
    }
  }
}
