package red.ochsenbein.voidweaver.player;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.robolectric.Shadows.shadowOf;

import android.app.Application;
import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.content.ComponentName;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.Uri;
import android.os.Build;
import android.os.Looper;
import android.view.KeyEvent;
import android.view.View;
import android.widget.TextView;
import androidx.annotation.Nullable;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MediaMetadata;
import androidx.media3.common.Player;
import androidx.media3.common.SimpleBasePlayer;
import androidx.media3.session.PlaybackPendingIntentBuilder;
import com.google.common.collect.ImmutableList;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.function.BooleanSupplier;
import java.util.List;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.GraphicsMode;
import org.robolectric.shadows.ShadowAppWidgetManager;
import org.robolectric.shadows.ShadowLooper;
import org.robolectric.shadows.ShadowNetwork;
import org.robolectric.shadows.ShadowNetworkCapabilities;

// Before Android 12 the widget picks its layout itself; from 12 on, the launcher
@Config(sdk = {Build.VERSION_CODES.P, Build.VERSION_CODES.VANILLA_ICE_CREAM})
// Real bitmaps, for the covers
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@RunWith(RobolectricTestRunner.class)
public final class PlayerWidgetTest {
  private static final String APP_ACTIVITY = "red.ochsenbein.voidweaver.MainActivity";

  private final Application context = RuntimeEnvironment.getApplication();
  private final List<PlayerSession> sessions = new ArrayList<>();
  private final List<String> commands = new ArrayList<>();
  private ShadowAppWidgetManager widgets;

  @Before
  public void setUp() {
    PlayerWidget.reset(context);
    RecentItem.clear(context);
    widgets = shadowOf(AppWidgetManager.getInstance(context));
    // The app's launcher activity, which the widget opens
    ComponentName activity = new ComponentName(context, APP_ACTIVITY);
    shadowOf(context.getPackageManager()).addActivityIfNotPresent(activity);
    IntentFilter launcher = new IntentFilter(Intent.ACTION_MAIN);
    launcher.addCategory(Intent.CATEGORY_LAUNCHER);
    shadowOf(context.getPackageManager()).addIntentFilterForActivity(activity, launcher);
  }

  @After
  public void tearDown() {
    for (PlayerSession session : sessions) {
      PlayerWidget.forget(context, session);
      session.session.release();
    }
    PlayerWidget.reset(context);
    RecentItem.clear(context);
    RecentItem.awaitIo();
    ShadowLooper.idleMainLooper();
  }

  private static Bitmap bitmap(int color) {
    Bitmap bitmap = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888);
    bitmap.eraseColor(color);
    return bitmap;
  }

  /** Whether the widget [id] shows a cover rather than the placeholder. */
  private boolean showsCover(int id) {
    View view = widgetView(id);
    return view.findViewById(R.id.voidweaver_widget_cover).getVisibility() == View.VISIBLE
        && view.findViewById(R.id.voidweaver_widget_cover_placeholder).getVisibility()
            == View.GONE;
  }

  /** Runs the main looper until the widget [id] shows a cover, or 5 seconds passed. */
  private boolean awaitCover(int id) throws InterruptedException {
    for (int i = 0; i < 500; i++) {
      RecentItem.awaitIo();
      if (showsCover(id)) return true;
      Thread.sleep(10);
    }
    return false;
  }

  /** Saves the recent track "r" with [color] as the cover the widget saved for it. */
  private String saveRecentWithCover(int color) {
    saveRecent("Recent");
    String key = RecentItem.coverKey("art-al-1");
    RecentItem.saveCover(context, "r", key, bitmap(color));
    RecentItem.awaitIo();
    return key;
  }

  /** Items "a", "b", "c" with titles, artists and albums, at [index]. */
  private static FakePlayer tracks(int index, boolean playing) {
    return tracks(index, playing, null);
  }

  /** {@link #tracks(int, boolean)} with [artworkUri] as the artwork of every item. */
  private static FakePlayer tracks(int index, boolean playing, @Nullable Uri artworkUri) {
    FakePlayer player = new FakePlayer(3);
    ImmutableList.Builder<SimpleBasePlayer.MediaItemData> playlist = ImmutableList.builder();
    for (int i = 0; i < 3; i++) {
      String id = String.valueOf((char) ('a' + i));
      playlist.add(
          new SimpleBasePlayer.MediaItemData.Builder(id)
              .setMediaItem(
                  new MediaItem.Builder()
                      .setMediaId(id)
                      .setMediaMetadata(
                          new MediaMetadata.Builder()
                              .setTitle("Title " + id)
                              .setArtist("Artist " + id)
                              .setAlbumTitle("Album")
                              .setArtworkUri(artworkUri)
                              .build())
                      .build())
              .setDurationUs(180_000_000)
              .build());
    }
    player.setState(
        player
            .state()
            .buildUpon()
            .setPlaylist(playlist.build())
            .setCurrentMediaItemIndex(index)
            .setPlayWhenReady(playing, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .build());
    return player;
  }

  /** The app's player as the session sees it, with [player] as its ExoPlayer. */
  private PlayerSession appSession(FakePlayer player) {
    SessionPlayer sessionPlayer =
        new SessionPlayer(
            player, (String command, @Nullable Long position) -> commands.add(command));
    sessionPlayer.setStopped(false);
    PlayerSession session = PlayerSession.create(context, "app", sessionPlayer);
    sessions.add(session);
    sessionPlayer.addListener(PlayerWidget.listener(context, session, sessionPlayer));
    return session;
  }

  private void saveRecent(String title) {
    RecentItem.save(
        context,
        new MediaItem.Builder()
            .setMediaId("r")
            .setMediaMetadata(
                new MediaMetadata.Builder().setTitle(title).setArtist("Recent artist").build())
            .build());
  }

  private int addWidget() {
    return widgets.createWidget(PlayerWidget.class, R.layout.voidweaver_widget);
  }

  private View widgetView(int id) {
    ShadowLooper.idleMainLooper();
    return widgets.getViewFor(id);
  }

  private static String text(View root, int id) {
    TextView view = root.findViewById(id);
    return view.getVisibility() == View.VISIBLE ? view.getText().toString() : null;
  }

  @Test
  public void showsTheTrackOfTheAppsPlayer() {
    PlayerSession session = appSession(tracks(1, true));

    PlayerWidget.State state = PlayerWidget.State.of(context, session);

    assertEquals(PlayerWidget.State.Kind.PLAYER, state.kind);
    assertEquals("Title b", state.title);
    assertEquals("Artist b", state.artist);
    assertEquals("Album", state.album);
    assertTrue(state.playing);
    assertTrue(state.canSkip);
    assertEquals("app", state.sessionId);
  }

  @Test
  public void showsTheRecentTrackWithoutAPlayer() {
    saveRecent("Recent");

    PlayerWidget.State state = PlayerWidget.State.recent(context, false, null);

    assertEquals(PlayerWidget.State.Kind.RECENT, state.kind);
    assertEquals("Recent", state.title);
    assertFalse(state.playing);
    // Only Play can start the app to resume it
    assertFalse(state.canSkip);
  }

  @Test
  public void showsNothingWithoutARecentTrack() {
    assertEquals(PlayerWidget.State.EMPTY, PlayerWidget.State.recent(context, false, null));
  }

  @Test
  public void showsTheRecentTrackWhileThePlayerHasNothingLoaded() {
    saveRecent("Recent");
    FakePlayer player = new FakePlayer(1);
    player.setState(
        player
            .state()
            .buildUpon()
            .setPlaylist(ImmutableList.of())
            .setPlaybackState(Player.STATE_IDLE)
            .build());
    PlayerSession session = appSession(player);

    assertEquals(PlayerWidget.State.Kind.RECENT, PlayerWidget.State.of(context, session).kind);
  }

  @Test
  public void showsTheRecentTrackAsPlayingOnceTheStandInWasAskedToPlay() {
    saveRecent("Recent");
    ResumePlayer resumePlayer = new ResumePlayer(Looper.getMainLooper(), "voidweaver", () -> {});
    PlayerSession session = PlayerSession.create(context, "resume", resumePlayer);
    sessions.add(session);

    assertFalse(PlayerWidget.State.of(context, session).playing);
    resumePlayer.play();
    ShadowLooper.idleMainLooper();

    PlayerWidget.State state = PlayerWidget.State.of(context, session);
    assertEquals(PlayerWidget.State.Kind.RECENT, state.kind);
    assertEquals("Recent", state.title);
    assertTrue(state.playing);
    assertEquals("resume", state.sessionId);
  }

  @Test
  public void followsThePlayer() {
    int id = addWidget();
    FakePlayer player = tracks(0, false);
    appSession(player);
    ShadowLooper.idleMainLooper();

    player.setState(player.state().buildUpon().setCurrentMediaItemIndex(2).build());
    View view = widgetView(id);

    assertEquals("Title c", text(view, R.id.voidweaver_widget_title));
    assertEquals("Artist c", text(view, R.id.voidweaver_widget_artist));
  }

  @Test
  public void showsTheRecentTrackOnceThePlayerIsReleased() {
    int id = addWidget();
    saveRecent("Recent");
    PlayerSession session = appSession(tracks(1, true));
    ShadowLooper.idleMainLooper();
    PlayerWidget.show(context, session);
    assertEquals("Title b", text(widgetView(id), R.id.voidweaver_widget_title));

    PlayerWidget.forget(context, session);

    assertEquals("Recent", text(widgetView(id), R.id.voidweaver_widget_title));
  }

  @Test
  public void showsNothingAfterALogout() {
    int id = addWidget();
    PlayerSession session = appSession(tracks(1, true));
    PlayerWidget.show(context, session);

    // As the plugin disposes a player on logout
    RecentItem.clear(context);
    PlayerWidget.forget(context, session);
    View view = widgetView(id);

    assertEquals("Nothing playing", text(view, R.id.voidweaver_widget_title));
    assertNull(text(view, R.id.voidweaver_widget_artist));
    assertEquals(View.GONE, view.findViewById(R.id.voidweaver_widget_play_pause).getVisibility());
    assertEquals(View.GONE, view.findViewById(R.id.voidweaver_widget_next).getVisibility());
    assertEquals(View.VISIBLE, view.findViewById(R.id.voidweaver_widget_random).getVisibility());
  }

  @Test
  public void playSendsAMediaButtonToThePlaybackService() {
    int id = addWidget();
    PlayerWidget.show(context, appSession(tracks(1, false)));
    View button = widgetView(id).findViewById(R.id.voidweaver_widget_play_pause);

    assertEquals("Play", button.getContentDescription().toString());
    button.performClick();

    Intent intent = shadowOf(context).getNextStartedService();
    assertNotNull(intent);
    assertEquals(Intent.ACTION_MEDIA_BUTTON, intent.getAction());
    assertEquals(PlaybackService.class.getName(), intent.getComponent().getClassName());
    KeyEvent key = intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT);
    assertEquals(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, key.getKeyCode());
  }

  @Test
  public void showsPauseWhilePlaying() {
    int id = addWidget();
    PlayerWidget.show(context, appSession(tracks(1, true)));

    View button = widgetView(id).findViewById(R.id.voidweaver_widget_play_pause);

    assertEquals("Pause", button.getContentDescription().toString());
  }

  @Test
  public void randomOpensTheAppWithTheShortcutsAction() {
    int id = addWidget();
    PlayerWidget.show(context, appSession(tracks(1, true)));

    widgetView(id).findViewById(R.id.voidweaver_widget_random).performClick();

    Intent intent = shadowOf(context).getNextStartedActivity();
    assertNotNull(intent);
    assertEquals(PlayerWidget.ACTION_PLAY_RANDOM, intent.getAction());
    assertEquals(APP_ACTIVITY, intent.getComponent().getClassName());
    assertTrue((intent.getFlags() & Intent.FLAG_ACTIVITY_CLEAR_TASK) != 0);
  }

  @Test
  public void drawsAWidgetAddedWithoutAPlayer() {
    saveRecent("Recent");
    int id = addWidget();

    // As the launcher asks for a new widget, in a process without a player
    new PlayerWidget()
        .onUpdate(context, AppWidgetManager.getInstance(context), new int[] {id});

    assertEquals("Recent", text(widgetView(id), R.id.voidweaver_widget_title));
  }

  @Test
  public void keysCoversByTheirCacheKey() {
    ArtworkLoader loader = ArtworkLoader.create(context);
    Uri first =
        loader.register("1", Uri.parse("https://music.example/art?id=al-1&t=a"), "art-al-1");
    Uri second =
        loader.register("2", Uri.parse("https://music.example/art?id=al-1&t=b"), "art-al-1");

    // The tracks of an album share the cover, so the widget keeps it across them
    assertEquals(loader.key(first), loader.key(second));
    assertNull(loader.key(Uri.parse("voidweaver-art://unknown")));
  }

  /** The stand-in for playback resumption, with the widget following it as PlaybackService does. */
  private PlayerSession standIn(ResumePlayer resumePlayer) {
    PlayerSession session = PlayerSession.create(context, "resume", resumePlayer);
    sessions.add(session);
    resumePlayer.addListener(PlayerWidget.listener(context, session, resumePlayer));
    return session;
  }

  private static String playPauseLabel(View view) {
    return view.findViewById(R.id.voidweaver_widget_play_pause).getContentDescription().toString();
  }

  /** The media button PendingIntent for Play/Pause to session [sessionId], if one was created. */
  @Nullable
  private PendingIntent existingPlayPause(boolean foreground, String sessionId) {
    Intent intent =
        PlaybackPendingIntentBuilder.createMediaButtonIntent(
            context, Player.COMMAND_PLAY_PAUSE, null, sessionId, PlaybackService.class);
    int flags = PendingIntent.FLAG_NO_CREATE | PendingIntent.FLAG_IMMUTABLE;
    return foreground
        ? PendingIntent.getForegroundService(
            context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, intent, flags)
        : PendingIntent.getService(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, intent, flags);
  }

  @Test
  public void ignoresAPlayerThatClaimedTheStandInsSessionUntilItTookItOver() {
    saveRecent("Recent");
    int id = addWidget();
    PlayerSession standIn = standIn(new ResumePlayer(Looper.getMainLooper(), "voidweaver", () -> {}));
    PlayerWidget.refresh(context);
    // The app's player, which claimed the stand-in's session (PlaylistPlayer)
    FakePlayer exoPlayer = tracks(0, false);
    SessionPlayer appPlayer =
        new SessionPlayer(exoPlayer, (String command, @Nullable Long position) -> {});
    appPlayer.setStopped(false);
    appPlayer.addListener(PlayerWidget.listener(context, standIn, appPlayer));

    exoPlayer.setState(exoPlayer.state().buildUpon().setCurrentMediaItemIndex(1).build());
    assertEquals("Recent", text(widgetView(id), R.id.voidweaver_widget_title));

    // PlaybackService.handOver()
    standIn.session.setPlayer(appPlayer);
    PlayerWidget.show(context, standIn);
    assertEquals("Title b", text(widgetView(id), R.id.voidweaver_widget_title));
  }

  @Test
  public void playMayStartTheServiceInTheForegroundButPauseDoesnt() {
    addWidget();
    FakePlayer player = tracks(1, false);
    PlayerWidget.show(context, appSession(player));
    ShadowLooper.idleMainLooper();

    // Paused: Play has to start the service if Android stopped it, which only a foreground start
    // may from the background
    assertNotNull(existingPlayPause(true, "app"));
    assertNull(existingPlayPause(false, "app"));

    player.setState(
        player
            .state()
            .buildUpon()
            .setPlayWhenReady(true, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .build());
    ShadowLooper.idleMainLooper();

    assertNotNull(existingPlayPause(false, "app"));
  }

  @Test
  public void sendsPlayToTheSessionShown() {
    int id = addWidget();
    PlayerWidget.show(context, appSession(tracks(1, false)));

    widgetView(id).findViewById(R.id.voidweaver_widget_play_pause).performClick();

    Intent intent = shadowOf(context).getNextStartedService();
    Uri sessionUri =
        PlaybackPendingIntentBuilder.createMediaButtonIntent(
                context, Player.COMMAND_PLAY_PAUSE, null, "app", PlaybackService.class)
            .getData();
    assertNotNull(sessionUri);
    assertEquals(sessionUri, intent.getData());
  }

  @Test
  public void nextGoesToTheAppsPlayer() {
    int id = addWidget();
    PlayerSession session = appSession(tracks(1, true));
    PlayerWidget.show(context, session);

    widgetView(id).findViewById(R.id.voidweaver_widget_next).performClick();
    ShadowLooper.idleMainLooper();

    // Not through PlaybackService, which Android may have stopped
    assertNull(shadowOf(context).getNextStartedService());
    assertEquals(List.of("next"), commands);
  }

  @Test
  public void nextDoesNothingWithoutTheAppsPlayer() {
    saveRecent("Recent");
    ResumePlayer resumePlayer = new ResumePlayer(Looper.getMainLooper(), "voidweaver", () -> {});
    PlayerWidget.show(context, standIn(resumePlayer));

    new PlayerWidget().onReceive(context, new Intent(PlayerWidget.ACTION_NEXT));
    ShadowLooper.idleMainLooper();

    assertFalse(resumePlayer.getPlayWhenReady());
    assertNull(shadowOf(context).getNextStartedService());
  }

  @Test
  public void redrawsWhenANewProcessStarts() {
    saveRecent("Recent");
    int id = addWidget();
    PlayerWidget.show(context, appSession(tracks(1, true)));
    assertEquals("Pause", playPauseLabel(widgetView(id)));

    // The process died; the launcher keeps its views. The next one starts the service or the app.
    PlayerWidget.reset(context);
    PlayerWidget.refresh(context);

    View view = widgetView(id);
    assertEquals("Recent", text(view, R.id.voidweaver_widget_title));
    assertEquals("Play", playPauseLabel(view));
  }

  @Test
  public void redrawsWhenAStaleSkipStartsANewProcess() {
    saveRecent("Recent");
    int id = addWidget();
    PlayerWidget.show(context, appSession(tracks(1, true)));
    commands.clear();

    PlayerWidget.reset(context);
    new PlayerWidget().onReceive(context, new Intent(PlayerWidget.ACTION_NEXT));

    View view = widgetView(id);
    assertEquals("Recent", text(view, R.id.voidweaver_widget_title));
    assertFalse(view.findViewById(R.id.voidweaver_widget_next).isEnabled());
    assertTrue(commands.isEmpty());
  }

  @Test
  public void refreshKeepsWhatThisProcessDrew() {
    saveRecent("Recent");
    int id = addWidget();
    ResumePlayer resumePlayer = new ResumePlayer(Looper.getMainLooper(), "voidweaver", () -> {});
    standIn(resumePlayer);
    resumePlayer.play();
    ShadowLooper.idleMainLooper();
    assertEquals("Pause", playPauseLabel(widgetView(id)));

    // The plugin attaches once the stand-in started the app
    PlayerWidget.refresh(context);

    assertEquals("Pause", playPauseLabel(widgetView(id)));
  }

  @Test
  public void offersNoSkipWhilePaused() {
    PlayerWidget.State state = PlayerWidget.State.of(context, appSession(tracks(1, false)));

    // A skip starts playback, which needs the service in the foreground, as it is while playing
    assertFalse(state.canSkip);
  }

  @Test
  public void ignoresASkipFromAWidgetDrawnWhilePlaying() {
    FakePlayer player = tracks(1, true);
    PlayerWidget.show(context, appSession(player));
    player.setState(
        player
            .state()
            .buildUpon()
            .setPlayWhenReady(false, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .build());
    ShadowLooper.idleMainLooper();

    new PlayerWidget().onReceive(context, new Intent(PlayerWidget.ACTION_NEXT));
    ShadowLooper.idleMainLooper();

    assertTrue(commands.isEmpty());
  }

  @Test
  public void pausingDimsNextAndItDoesNothing() {
    int id = addWidget();
    FakePlayer player = tracks(1, true);
    PlayerSession session = appSession(player);
    PlayerWidget.show(context, session);
    assertTrue(widgetView(id).findViewById(R.id.voidweaver_widget_next).isEnabled());

    player.setState(
        player
            .state()
            .buildUpon()
            .setPlayWhenReady(false, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .build());
    View next = widgetView(id).findViewById(R.id.voidweaver_widget_next);

    assertFalse(next.isEnabled());
    // No PendingIntent behind it either
    next.performClick();
    ShadowLooper.idleMainLooper();
    assertTrue(shadowOf(context).getBroadcastIntents().isEmpty());
    assertTrue(commands.isEmpty());
  }

  @Test
  public void countsBufferingAfterPlayAsPlaying() {
    FakePlayer player = tracks(1, true);
    player.setState(player.state().buildUpon().setPlaybackState(Player.STATE_BUFFERING).build());

    PlayerWidget.State state = PlayerWidget.State.of(context, appSession(player));

    assertTrue(state.playing);
    assertTrue(state.canSkip);
  }

  @Test
  public void showsTheCoverSavedForTheRecentTrack() throws Exception {
    saveRecentWithCover(Color.RED);
    int id = addWidget();

    new PlayerWidget()
        .onUpdate(context, AppWidgetManager.getInstance(context), new int[] {id});

    assertTrue(awaitCover(id));
    assertEquals("Recent", text(widgetView(id), R.id.voidweaver_widget_title));
  }

  @Test
  public void showsThePlaceholderWithoutASavedCover() throws Exception {
    saveRecent("Recent");
    int id = addWidget();

    new PlayerWidget()
        .onUpdate(context, AppWidgetManager.getInstance(context), new int[] {id});
    RecentItem.awaitIo();

    assertFalse(showsCover(id));
  }

  @Test
  public void aSavedCoverReadBeforeALogoutIsntShownAfterIt() throws Exception {
    saveRecentWithCover(Color.RED);
    int id = addWidget();
    PlayerSession session = appSession(tracks(1, true));
    PlayerWidget.show(context, session);
    // The recent track shows once the player is released: its cover is read ...
    PlayerWidget.forget(context, session);
    RecentItem.awaitIo();
    // ... and posted, but the logout comes first (the main looper hasn't run the post yet)
    PlayerWidget.show(context, session);
    RecentItem.clear(context);
    PlayerWidget.forget(context, session);

    assertFalse(showsCover(id));
    assertEquals("Nothing playing", text(widgetView(id), R.id.voidweaver_widget_title));
  }

  @Test
  public void savesTheCoverOfThePlayersTrackForLater() throws Exception {
    // Artwork without a cache key, read from a file here, keyed by its URL
    File art = new File(context.getCacheDir(), "art.png");
    try (OutputStream out = new FileOutputStream(art)) {
      bitmap(Color.BLUE).compress(Bitmap.CompressFormat.PNG, 100, out);
    }
    FakePlayer player = tracks(1, true);
    PlayerSession session = appSession(player);
    // As PlaylistPlayer registers it, before the items have it
    Uri artworkUri = session.artwork.register("b", Uri.fromFile(art), null);
    player.setState(tracks(1, true, artworkUri).state());
    // As PlaylistPlayer saves the current track
    RecentItem.save(context, new MediaItem.Builder().setMediaId("b").build());
    int id = addWidget();

    PlayerWidget.show(context, session);
    assertTrue(awaitCover(id));
    RecentItem.awaitIo();

    String key = RecentItem.coverKey(Uri.fromFile(art).toString());
    assertEquals(key, RecentItem.savedCoverKey(context));

    // Once the app's player is gone, the recent track keeps it, read from the saved file
    PlayerWidget.reset(context);
    new PlayerWidget()
        .onUpdate(context, AppWidgetManager.getInstance(context), new int[] {id});
    assertTrue(awaitCover(id));
  }

  @Test
  public void savesAJpegCoverAsJpeg() throws Exception {
    // As most servers deliver covers: a JPEG, larger than the widget's size, so it's scaled
    File art = new File(context.getCacheDir(), "art.jpg");
    Bitmap source = Bitmap.createBitmap(640, 480, Bitmap.Config.ARGB_8888);
    source.eraseColor(Color.BLUE);
    try (OutputStream out = new FileOutputStream(art)) {
      source.compress(Bitmap.CompressFormat.JPEG, 90, out);
    }
    FakePlayer player = tracks(1, true);
    PlayerSession session = appSession(player);
    Uri artworkUri = session.artwork.register("b", Uri.fromFile(art), null);
    player.setState(tracks(1, true, artworkUri).state());
    RecentItem.save(context, new MediaItem.Builder().setMediaId("b").build());
    int id = addWidget();

    PlayerWidget.show(context, session);
    assertTrue(awaitCover(id));
    RecentItem.awaitIo();

    // Decoded through the session's loader and scaled, it has no alpha: saved as a JPEG
    byte[] saved =
        java.nio.file.Files.readAllBytes(
            new File(context.getNoBackupFilesDir(), RecentItem.COVER_FILE).toPath());
    assertEquals((byte) 0xFF, saved[0]);
    assertEquals((byte) 0xD8, saved[1]);
  }

  // Retrying a cover that failed for the network

  private static final Network WIFI = ShadowNetwork.newInstance(1);
  private static final Network MOBILE = ShadowNetwork.newInstance(2);

  private ConnectivityManager connectivity() {
    return context.getSystemService(ConnectivityManager.class);
  }

  private static NetworkCapabilities validated() {
    NetworkCapabilities capabilities = ShadowNetworkCapabilities.newInstance();
    shadowOf(capabilities).addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET);
    shadowOf(capabilities).addCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
    return capabilities;
  }

  /** Whether the device has a validated network when the widget starts waiting for one. */
  private void setOnline(boolean online) {
    shadowOf(connectivity()).setDefaultNetworkActive(true);
    Network active = connectivity().getActiveNetwork();
    if (active == null) {
      assertFalse(online);
      return;
    }
    NetworkCapabilities capabilities =
        online ? validated() : ShadowNetworkCapabilities.newInstance();
    shadowOf(connectivity()).setNetworkCapabilities(active, capabilities);
  }

  /** The callbacks registered with ConnectivityManager. */
  private List<ConnectivityManager.NetworkCallback> networkCallbacks() {
    return new ArrayList<>(shadowOf(connectivity()).getNetworkCallbacks());
  }

  /** Reports [network] as the validated default network to the widget's callback. */
  private void networkAvailable(Network network) {
    List<ConnectivityManager.NetworkCallback> callbacks = networkCallbacks();
    assertEquals(1, callbacks.size());
    callbacks.get(0).onCapabilitiesChanged(network, validated());
    ShadowLooper.idleMainLooper();
  }

  /** Runs the main looper until [condition] holds, or 5 seconds passed. */
  private static boolean await(BooleanSupplier condition) throws InterruptedException {
    for (int i = 0; i < 500; i++) {
      ShadowLooper.idleMainLooper();
      if (condition.getAsBoolean()) return true;
      Thread.sleep(10);
    }
    return false;
  }

  private int failures;

  /** The player of {@link #playerWithMissingArt}. */
  private FakePlayer artPlayer;

  /**
   * Shows the app's player with item "b", whose artwork is the file [art] (missing for now), and
   * counts the failed loads; they're retried as if the network had failed.
   */
  private PlayerSession playerWithMissingArt(File art) {
    failures = 0;
    PlayerWidget.coverRetry.retryable =
        failure -> {
          failures++;
          return failure instanceof FileNotFoundException
              || failure.getCause() instanceof FileNotFoundException;
        };
    artPlayer = tracks(1, true);
    PlayerSession session = appSession(artPlayer);
    Uri artworkUri = session.artwork.register("b", Uri.fromFile(art), null);
    artPlayer.setState(tracks(1, true, artworkUri).state());
    PlayerWidget.show(context, session);
    return session;
  }

  private File missingArt() {
    File art = new File(context.getCacheDir(), "missing-art.png");
    assertTrue(!art.exists() || art.delete());
    return art;
  }

  private static void writeArt(File art) throws Exception {
    try (OutputStream out = new FileOutputStream(art)) {
      bitmap(Color.GREEN).compress(Bitmap.CompressFormat.PNG, 100, out);
    }
  }

  @Test
  public void loadsTheCoverAgainWhenANetworkComesBack() throws Exception {
    setOnline(false);
    File art = missingArt();
    int id = addWidget();
    playerWithMissingArt(art);
    assertTrue(await(() -> failures == 1));
    assertTrue(PlayerWidget.coverRetry.isWaiting());
    assertFalse(showsCover(id));

    writeArt(art);
    networkAvailable(WIFI);

    assertTrue(awaitCover(id));
    // Done waiting
    assertFalse(PlayerWidget.coverRetry.isWaiting());
    assertTrue(networkCallbacks().isEmpty());
  }

  @Test
  public void ignoresTheNetworkThatWasThereWhenTheLoadFailed() throws Exception {
    setOnline(true);
    File art = missingArt();
    int id = addWidget();
    playerWithMissingArt(art);
    assertTrue(await(() -> failures == 1));
    writeArt(art);

    // Registering reports the network the load just failed on
    networkAvailable(WIFI);
    Thread.sleep(200);
    ShadowLooper.idleMainLooper();
    assertFalse(showsCover(id));

    // Another one
    networkAvailable(MOBILE);
    assertTrue(awaitCover(id));
  }

  @Test
  public void triesAFewTimesAtMost() throws Exception {
    setOnline(false);
    int id = addWidget();
    playerWithMissingArt(missingArt());
    assertTrue(await(() -> failures == 1));

    for (int i = 1; i <= CoverRetry.MAX_RETRIES; i++) {
      // Waits for one network at a time, through one callback
      assertEquals(1, networkCallbacks().size());
      networkAvailable(i % 2 == 0 ? WIFI : MOBILE);
      int failed = i + 1;
      assertTrue(await(() -> failures == failed));
    }
    assertFalse(PlayerWidget.coverRetry.isWaiting());
    assertTrue(networkCallbacks().isEmpty());

    // Drawn again for the same cover (a pause): its tries still count
    Uri artworkUri = artPlayer.getMediaMetadata().artworkUri;
    artPlayer.setState(tracks(1, false, artworkUri).state());
    ShadowLooper.idleMainLooper();
    assertFalse(PlayerWidget.coverRetry.isWaiting());
    assertFalse(showsCover(id));
  }

  @Test
  public void doesNotRetryWhenTheServerAnswered() throws Exception {
    setOnline(false);
    File art = missingArt();
    playerWithMissingArt(art);
    // The real check: the missing file is no network failure
    PlayerWidget.coverRetry.retryable =
        failure -> {
          failures++;
          return CoverRetry.isNetworkFailure(failure);
        };
    assertTrue(await(() -> failures == 1));

    assertFalse(PlayerWidget.coverRetry.isWaiting());
    assertTrue(networkCallbacks().isEmpty());
  }

  @Test
  public void stopsWaitingForAnotherCover() throws Exception {
    setOnline(false);
    playerWithMissingArt(missingArt());
    assertTrue(await(() -> failures == 1));
    assertTrue(PlayerWidget.coverRetry.isWaiting());

    // The next track has no cover
    artPlayer.setState(tracks(2, true, null).state());
    ShadowLooper.idleMainLooper();

    assertFalse(PlayerWidget.coverRetry.isWaiting());
    assertTrue(networkCallbacks().isEmpty());
  }

  @Test
  public void stopsWaitingWhenThePlayerIsGone() throws Exception {
    setOnline(false);
    PlayerSession session = playerWithMissingArt(missingArt());
    assertTrue(await(() -> failures == 1));

    PlayerWidget.forget(context, session);

    assertFalse(PlayerWidget.coverRetry.isWaiting());
    assertTrue(networkCallbacks().isEmpty());
  }
}
