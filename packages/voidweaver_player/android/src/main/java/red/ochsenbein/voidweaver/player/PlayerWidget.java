package red.ochsenbein.voidweaver.player;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.util.SizeF;
import android.view.View;
import android.widget.RemoteViews;
import androidx.annotation.Nullable;
import androidx.annotation.VisibleForTesting;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MediaMetadata;
import androidx.media3.common.Player;
import androidx.media3.common.util.Util;
import androidx.media3.session.PlaybackPendingIntentBuilder;
import com.google.common.util.concurrent.FutureCallback;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;
import com.google.common.util.concurrent.MoreExecutors;
import java.util.Map;
import java.util.Objects;

/**
 * The home screen widget: the current track with its cover, Previous, Play/Pause and Next, and a
 * button that starts random songs.
 *
 * <p>It shows the player of the session that played last ({@link #listener}): the app's player
 * while there is one, the track saved for playback resumption ({@link RecentItem}) after the app
 * was closed, or nothing after a logout. The launcher keeps the last views after the process died.
 *
 * <p>Play/Pause sends a media button intent to {@link PlaybackService}, built by Media3 for
 * widgets ({@link PlaybackPendingIntentBuilder}): the path the notification's buttons take, so Play
 * also starts the service again after Android stopped it, or the app to resume playback, see {@link
 * ResumePlayer}. Previous and Next come back to this receiver ({@link #skipIntent}). The random
 * button opens the app with the launcher shortcut's intent ({@link #ACTION_PLAY_RANDOM}).
 *
 * <p>Everything runs on the main thread.
 */
public final class PlayerWidget extends AppWidgetProvider {
  private static final String TAG = "VoidweaverWidget";

  /**
   * Starts random songs and opens the app; the launcher shortcut's action, handled by the app's
   * {@code MainActivity}. Pinned shortcuts refer to it: keep it.
   */
  public static final String ACTION_PLAY_RANDOM = "red.ochsenbein.voidweaver.action.PLAY_RANDOM";

  /** The largest side of the cover handed to the launcher; views with bitmaps go through IPC. */
  private static final int COVER_SIZE_PX = 320;

  /** From this height on (dp), the widget shows the larger layout, with Previous and the album. */
  private static final float TALL_MIN_HEIGHT_DP = 120;

  private static final float MIN_WIDTH_DP = 250;

  // Previous and Next, handled in onReceive(), see skipIntent()
  @VisibleForTesting
  static final String ACTION_PREVIOUS = "red.ochsenbein.voidweaver.player.widget.PREVIOUS";

  @VisibleForTesting
  static final String ACTION_NEXT = "red.ochsenbein.voidweaver.player.widget.NEXT";

  // Alpha of a button that can't be used (Material's disabled content: 38%)
  private static final int ENABLED_ALPHA = 255;
  private static final int DISABLED_ALPHA = 97;

  private static final Handler handler = new Handler(Looper.getMainLooper());

  /** The session whose player the widgets show; null shows the recent track, or nothing. */
  @Nullable private static PlayerSession shownSession;

  /** What the widgets show, null before the first update in this process. */
  @Nullable private static State shown;

  /** The cover of {@link #shown}, once loaded. */
  @Nullable private static Cover cover;

  /** What a widget shows. */
  @VisibleForTesting
  static final class State {
    enum Kind {
      /** Nothing to play: logged out, or nothing played yet. */
      EMPTY,
      /** The track saved for playback resumption: Play starts the app to resume it. */
      RECENT,
      /** A track of the app's player. */
      PLAYER
    }

    final Kind kind;
    @Nullable final String title;
    @Nullable final String artist;
    @Nullable final String album;
    @Nullable final Uri artworkUri;

    /** Tells covers apart, see {@link ArtworkLoader#key}. Null: no cover. */
    @Nullable final String artworkKey;

    /** Shows Pause rather than Play. */
    final boolean playing;

    final boolean canGoBack;
    final boolean canSkip;

    /** The session the buttons go to, null for the one PlaybackService picks. */
    @Nullable final String sessionId;

    State(
        Kind kind,
        @Nullable String title,
        @Nullable String artist,
        @Nullable String album,
        @Nullable Uri artworkUri,
        @Nullable String artworkKey,
        boolean playing,
        boolean canGoBack,
        boolean canSkip,
        @Nullable String sessionId) {
      this.kind = kind;
      this.title = title;
      this.artist = artist;
      this.album = album;
      this.artworkUri = artworkUri;
      this.artworkKey = artworkKey;
      this.playing = playing;
      this.canGoBack = canGoBack;
      this.canSkip = canSkip;
      this.sessionId = sessionId;
    }

    static final State EMPTY =
        new State(Kind.EMPTY, null, null, null, null, null, false, false, false, null);

    /** The recent track; [playing] while the stand-in waits for the app to resume it. */
    static State recent(Context context, boolean playing, @Nullable String sessionId) {
      MediaItem item = RecentItem.load(context);
      if (item == null) return EMPTY;
      MediaMetadata metadata = item.mediaMetadata;
      return new State(
          Kind.RECENT,
          string(metadata.title),
          string(metadata.artist),
          string(metadata.albumTitle),
          null,
          null,
          playing,
          false,
          false,
          sessionId);
    }

    /** What [session]'s player shows. */
    static State of(Context context, PlayerSession session) {
      Player player = session.session.getPlayer();
      String sessionId = session.session.getId();
      if (player instanceof ResumePlayer) {
        // Standing in until the app runs: it only knows whether Play was pressed
        return recent(context, player.getPlayWhenReady(), sessionId);
      }
      if (!player.isCommandAvailable(Player.COMMAND_GET_CURRENT_MEDIA_ITEM)
          || player.getCurrentMediaItem() == null) {
        // Nothing loaded yet, e.g. while the app restores its queue
        return recent(context, false, sessionId);
      }
      MediaMetadata metadata = player.getMediaMetadata();
      Uri artworkUri = metadata.artworkUri;
      String artworkKey = artworkUri != null ? session.artwork.key(artworkUri) : null;
      // Also while buffering after Play (playWhenReady): the service is in the foreground then
      boolean playing = !Util.shouldShowPlayButton(player);
      return new State(
          Kind.PLAYER,
          string(metadata.title),
          string(metadata.artist),
          string(metadata.albumTitle),
          artworkKey != null ? artworkUri : null,
          artworkKey,
          playing,
          // Only while playing, see skip()
          playing && player.isCommandAvailable(Player.COMMAND_SEEK_TO_PREVIOUS),
          playing && player.isCommandAvailable(Player.COMMAND_SEEK_TO_NEXT),
          sessionId);
    }

    @Override
    public boolean equals(Object o) {
      if (!(o instanceof State)) return false;
      State other = (State) o;
      return kind == other.kind
          && Objects.equals(title, other.title)
          && Objects.equals(artist, other.artist)
          && Objects.equals(album, other.album)
          && Objects.equals(artworkUri, other.artworkUri)
          && Objects.equals(artworkKey, other.artworkKey)
          && playing == other.playing
          && canGoBack == other.canGoBack
          && canSkip == other.canSkip
          && Objects.equals(sessionId, other.sessionId);
    }

    @Override
    public int hashCode() {
      return Objects.hash(
          kind, title, artist, album, artworkUri, artworkKey, playing, canGoBack, canSkip,
          sessionId);
    }
  }

  /** A loaded cover, scaled down, and the {@link ArtworkLoader#key} it was loaded for. */
  private static final class Cover {
    final String key;
    final Bitmap bitmap;

    Cover(String key, Bitmap bitmap) {
      this.key = key;
      this.bitmap = bitmap;
    }
  }

  /**
   * Keeps the widgets showing [player] while it's the player of [session]. Add it to [player]:
   * the app's player, or the stand-in for playback resumption. A player that claimed the stand-in's
   * session only shows once it took the session over, see {@link PlaybackService#handOver}.
   */
  static Player.Listener listener(Context context, PlayerSession session, Player player) {
    Context app = context.getApplicationContext();
    return new Player.Listener() {
      @Override
      public void onEvents(Player eventPlayer, Player.Events events) {
        if (session.session.getPlayer() == player) show(app, session);
      }
    };
  }

  /** Shows [session]'s player, e.g. after it got a new one. */
  static void show(Context context, PlayerSession session) {
    shownSession = session;
    update(context.getApplicationContext());
  }

  /** [session] is released: the widgets show the recent track, or nothing after a logout. */
  static void forget(Context context, PlayerSession session) {
    if (shownSession != session) return;
    shownSession = null;
    update(context.getApplicationContext());
  }

  /**
   * Draws the widgets once in a new process: the launcher keeps what the last process drew, which
   * may be a playing track whose Pause would now start playback (a media button to the stand-in).
   * Called where a process starts playback code: {@link PlaybackService#onCreate} (also when
   * Android restarts it after a crash) and the plugin.
   */
  static void refresh(Context context) {
    if (shown == null) update(context.getApplicationContext());
  }

  private static State current(Context context) {
    return shownSession != null
        ? State.of(context, shownSession)
        : State.recent(context, false, null);
  }

  private static void update(Context context) {
    State state = current(context);
    if (state.equals(shown)) return;
    shown = state;
    if (cover != null && !cover.key.equals(state.artworkKey)) cover = null;
    render(context, widgetIds(context));
    if (cover == null && state.artworkUri != null && shownSession != null) {
      loadCover(context, shownSession, state.artworkUri, state.artworkKey);
    }
  }

  /**
   * Loads the cover through the session's bitmap loader, which caches the last one: the
   * notification usually loaded it already. Also offline, see {@link ArtworkLoader}.
   */
  private static void loadCover(Context context, PlayerSession session, Uri uri, String key) {
    ListenableFuture<Bitmap> future;
    try {
      future = session.session.getBitmapLoader().loadBitmap(uri);
    } catch (RuntimeException e) {
      Log.w(TAG, "Could not load the cover", e);
      return;
    }
    Futures.addCallback(
        future,
        new FutureCallback<Bitmap>() {
          @Override
          public void onSuccess(Bitmap bitmap) {
            // On the loader's thread, or here if it was cached
            Bitmap scaled = scale(bitmap);
            handler.post(
                () -> {
                  if (shown == null || !key.equals(shown.artworkKey)) return;
                  cover = new Cover(key, scaled);
                  render(context, widgetIds(context));
                });
          }

          @Override
          public void onFailure(Throwable t) {
            // The placeholder stays
            Log.w(TAG, "Could not load the cover: " + t);
          }
        },
        MoreExecutors.directExecutor());
  }

  private static Bitmap scale(Bitmap bitmap) {
    int width = bitmap.getWidth();
    int height = bitmap.getHeight();
    int largest = Math.max(width, height);
    if (largest <= COVER_SIZE_PX) return bitmap;
    float factor = (float) COVER_SIZE_PX / largest;
    return Bitmap.createScaledBitmap(
        bitmap,
        Math.max(1, Math.round(width * factor)),
        Math.max(1, Math.round(height * factor)),
        /* filter= */ true);
  }

  private static int[] widgetIds(Context context) {
    return AppWidgetManager.getInstance(context)
        .getAppWidgetIds(new ComponentName(context, PlayerWidget.class));
  }

  /** Puts the current state on the widgets [ids]. */
  private static void render(Context context, int[] ids) {
    if (ids.length == 0) return;
    AppWidgetManager manager = AppWidgetManager.getInstance(context);
    State state = shown != null ? shown : current(context);
    Bitmap bitmap =
        cover != null && cover.key.equals(state.artworkKey) ? cover.bitmap : null;
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      // The launcher picks the layout for the widget's size, also when it's resized
      RemoteViews views =
          new RemoteViews(
              Map.of(
                  new SizeF(MIN_WIDTH_DP, 0),
                  views(context, false, state, bitmap),
                  new SizeF(MIN_WIDTH_DP, TALL_MIN_HEIGHT_DP),
                  views(context, true, state, bitmap)));
      manager.updateAppWidget(ids, views);
    } else {
      for (int id : ids) {
        manager.updateAppWidget(id, views(context, isTall(manager, id), state, bitmap));
      }
    }
  }

  /** Before Android 12, the layout follows the widget's height in portrait. */
  private static boolean isTall(AppWidgetManager manager, int id) {
    Bundle options = manager.getAppWidgetOptions(id);
    return options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 0) >= TALL_MIN_HEIGHT_DP;
  }

  @VisibleForTesting
  static RemoteViews views(Context context, boolean tall, State state, @Nullable Bitmap bitmap) {
    RemoteViews views =
        new RemoteViews(
            context.getPackageName(),
            tall ? R.layout.voidweaver_widget : R.layout.voidweaver_widget_compact);
    boolean empty = state.kind == State.Kind.EMPTY;

    views.setTextViewText(
        R.id.voidweaver_widget_title,
        empty || state.title == null
            ? context.getString(R.string.voidweaver_widget_nothing_playing)
            : state.title);
    setOptionalText(views, R.id.voidweaver_widget_artist, empty ? null : state.artist);
    if (tall) setOptionalText(views, R.id.voidweaver_widget_album, empty ? null : state.album);

    if (bitmap != null) {
      views.setImageViewBitmap(R.id.voidweaver_widget_cover, bitmap);
      views.setViewVisibility(R.id.voidweaver_widget_cover, View.VISIBLE);
      views.setViewVisibility(R.id.voidweaver_widget_cover_placeholder, View.GONE);
    } else {
      views.setViewVisibility(R.id.voidweaver_widget_cover, View.GONE);
      views.setViewVisibility(R.id.voidweaver_widget_cover_placeholder, View.VISIBLE);
    }

    PendingIntent openApp = PlaybackService.sessionActivity(context);
    if (openApp != null) views.setOnClickPendingIntent(android.R.id.background, openApp);

    int transport = empty ? View.GONE : View.VISIBLE;
    views.setViewVisibility(R.id.voidweaver_widget_play_pause, transport);
    views.setViewVisibility(R.id.voidweaver_widget_next, transport);
    if (tall) views.setViewVisibility(R.id.voidweaver_widget_previous, transport);
    if (!empty) {
      views.setImageViewResource(
          R.id.voidweaver_widget_play_pause,
          state.playing
              ? androidx.media3.session.R.drawable.media3_icon_pause
              : androidx.media3.session.R.drawable.media3_icon_play);
      views.setContentDescription(
          R.id.voidweaver_widget_play_pause,
          context.getString(
              state.playing ? R.string.voidweaver_widget_pause : R.string.voidweaver_widget_play));
      views.setOnClickPendingIntent(
          R.id.voidweaver_widget_play_pause,
          new PlaybackPendingIntentBuilder(
                  context, Player.COMMAND_PLAY_PAUSE, PlaybackService.class)
              // Play may have to start the service (Android stops it while the app is paused in
              // the background) or the app; Pause only comes while it runs in the foreground
              .setStartAsForegroundService(!state.playing)
              .setSessionId(state.sessionId)
              .build());
      setSkipButton(context, views, R.id.voidweaver_widget_next, ACTION_NEXT, state.canSkip);
      if (tall) {
        setSkipButton(
            context, views, R.id.voidweaver_widget_previous, ACTION_PREVIOUS, state.canGoBack);
      }
    }
    views.setOnClickPendingIntent(R.id.voidweaver_widget_random, playRandom(context));
    return views;
  }

  private static void setSkipButton(
      Context context, RemoteViews views, int id, String action, boolean enabled) {
    views.setBoolean(id, "setEnabled", enabled);
    views.setInt(id, "setImageAlpha", enabled ? ENABLED_ALPHA : DISABLED_ALPHA);
    views.setOnClickPendingIntent(id, enabled ? skipIntent(context, action) : null);
  }

  /**
   * Previous and Next go to this receiver, which passes them to the player (and on to Dart), rather
   * than to {@link PlaybackService} as media buttons. Only Play may start the service from the
   * background, as a foreground service; a plain start is refused while it's stopped (after a stop,
   * or about 10 minutes after a pause), and Media3 only puts it in the foreground for Play. They're
   * only enabled while playing, see {@link #skip}.
   */
  private static PendingIntent skipIntent(Context context, String action) {
    Intent intent = new Intent(context, PlayerWidget.class).setAction(action);
    return PendingIntent.getBroadcast(
        context, 0, intent, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
  }

  /**
   * Previous or Next on a widget: moves the app's player (through {@link SessionPlayer}, to Dart,
   * as any controller would), if it's the one shown and can move that way.
   *
   * <p>Only while it plays. A skip starts playback (in Dart), which needs the service in the
   * foreground; it is while playing. Paused, the service may be stopped or out of the foreground,
   * and this receiver may not start it: playback would run without a foreground service, which
   * Android freezes. Bluetooth buttons don't have that problem, as Android lets the app start it for
   * a media button.
   */
  private static void skip(boolean forward) {
    PlayerSession session = shownSession;
    Player player = session != null ? session.session.getPlayer() : null;
    if (!(player instanceof SessionPlayer)) {
      // No player, or the stand-in for playback resumption: Play resumes, skipping can't
      Log.i(TAG, "Skip ignored: the app's player isn't running");
      return;
    }
    if (Util.shouldShowPlayButton(player)) {
      // A widget drawn while playing
      Log.i(TAG, "Skip ignored: not playing");
      return;
    }
    if (forward) {
      if (player.isCommandAvailable(Player.COMMAND_SEEK_TO_NEXT)) player.seekToNext();
    } else if (player.isCommandAvailable(Player.COMMAND_SEEK_TO_PREVIOUS)) {
      player.seekToPrevious();
    }
  }

  private static void setOptionalText(RemoteViews views, int id, @Nullable String text) {
    boolean present = text != null && !text.isEmpty();
    views.setTextViewText(id, present ? text : "");
    views.setViewVisibility(id, present ? View.VISIBLE : View.GONE);
  }

  /**
   * Opens the app with the launcher shortcut's intent, which starts random songs. With the flags
   * launchers start a shortcut with, so the app sees it as it sees the shortcut.
   */
  @Nullable
  private static PendingIntent playRandom(Context context) {
    Intent intent =
        context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
    if (intent == null) return null;
    intent.removeCategory(Intent.CATEGORY_LAUNCHER);
    intent
        .setAction(ACTION_PLAY_RANDOM)
        .setFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK
                | Intent.FLAG_ACTIVITY_CLEAR_TASK
                | Intent.FLAG_ACTIVITY_TASK_ON_HOME);
    return PendingIntent.getActivity(
        context, 0, intent, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
  }

  @Nullable
  private static String string(@Nullable CharSequence value) {
    return value == null ? null : value.toString();
  }

  @Override
  public void onReceive(Context context, Intent intent) {
    String action = intent.getAction();
    if (ACTION_NEXT.equals(action) || ACTION_PREVIOUS.equals(action)) {
      // A tap on a widget drawn by an earlier process starts a new one: draw it as it is now
      refresh(context);
      skip(ACTION_NEXT.equals(action));
      return;
    }
    super.onReceive(context, intent);
  }

  /** A widget was added, the device started, or the app was updated. */
  @Override
  public void onUpdate(Context context, AppWidgetManager manager, int[] ids) {
    render(context, ids);
  }

  /** Resized: before Android 12, the layout is picked here. */
  @Override
  public void onAppWidgetOptionsChanged(
      Context context, AppWidgetManager manager, int id, Bundle options) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) render(context, new int[] {id});
  }

  @VisibleForTesting
  static void reset() {
    shownSession = null;
    shown = null;
    cover = null;
  }
}
