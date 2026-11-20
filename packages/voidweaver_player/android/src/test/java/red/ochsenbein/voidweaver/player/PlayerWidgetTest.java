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
import java.util.ArrayList;
import java.util.List;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowAppWidgetManager;
import org.robolectric.shadows.ShadowLooper;

// Before Android 12 the widget picks its layout itself; from 12 on, the launcher
@Config(sdk = {Build.VERSION_CODES.P, Build.VERSION_CODES.VANILLA_ICE_CREAM})
@RunWith(RobolectricTestRunner.class)
public final class PlayerWidgetTest {
  private static final String APP_ACTIVITY = "red.ochsenbein.voidweaver.MainActivity";

  private final Application context = RuntimeEnvironment.getApplication();
  private final List<PlayerSession> sessions = new ArrayList<>();
  private final List<String> commands = new ArrayList<>();
  private ShadowAppWidgetManager widgets;

  @Before
  public void setUp() {
    PlayerWidget.reset();
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
    PlayerWidget.reset();
    RecentItem.clear(context);
    ShadowLooper.idleMainLooper();
  }

  /** Items "a", "b", "c" with titles, artists and albums, at [index]. */
  private static FakePlayer tracks(int index, boolean playing) {
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
    PlayerWidget.reset();
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

    PlayerWidget.reset();
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
}
