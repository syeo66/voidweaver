package red.ochsenbein.voidweaver.player;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
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
import androidx.media3.datasource.HttpDataSource;
import androidx.media3.session.PlaybackPendingIntentBuilder;
import com.google.common.util.concurrent.FutureCallback;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;
import com.google.common.util.concurrent.MoreExecutors;
import java.net.SocketException;
import java.net.SocketTimeoutException;
import java.net.UnknownHostException;
import java.util.Map;
import java.util.Objects;
import java.util.function.Predicate;

/**
 * The home screen widget: the current track with its cover, Play/Pause and Next, and a
 * button that starts random songs.
 *
 * <p>It shows the player of the session that played last ({@link #listener}): the app's player
 * while there is one, the track saved for playback resumption ({@link RecentItem}) after the app
 * was closed, with the cover the widget saved for it, or nothing after a logout. The launcher keeps
 * the last views after the process died.
 *
 * <p>Play/Pause sends a media button intent to {@link PlaybackService}, built by Media3 for
 * widgets ({@link PlaybackPendingIntentBuilder}): the path the notification's buttons take, so Play
 * also starts the service again after Android stopped it, or the app to resume playback, see {@link
 * ResumePlayer}. Next comes back to this receiver ({@link #skipIntent}). The random
 * button opens the app with the launcher shortcut's intent ({@link #ACTION_PLAY_RANDOM}).
 *
 * <p>A cover that couldn't be loaded for the network is loaded again when a network is back, a few
 * times at most, see {@link #coverFailed}.
 *
 * <p>Everything here runs on the main thread: the static fields are only touched there. Covers are
 * loaded on the session's bitmap loader or {@link RecentItem}'s thread, and posted back; network
 * events are posted too.
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

  /** From this height on (dp), the widget shows the larger layout, with the album. */
  private static final float TALL_MIN_HEIGHT_DP = 120;

  private static final float MIN_WIDTH_DP = 250;

  // Next, handled in onReceive(), see skipIntent()
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

  /** How often a cover is loaded again after a network failure, see {@link #coverFailed}. */
  @VisibleForTesting static final int MAX_RETRIES = 3;

  /** The cover that failed for the network last, and how often it was loaded again since. */
  @Nullable private static String retryKey;

  private static int retries;

  /** Registered while {@link #retryKey} waits for a network, see {@link #waitForNetwork}. */
  @Nullable private static ConnectivityManager.NetworkCallback retryCallback;

  /** The next network event is the network that was there on registering: none came back. */
  private static boolean skipCurrentNetwork;

  /** Which load failures are retried; the tests replace it. */
  @VisibleForTesting static Predicate<Throwable> retryable = PlayerWidget::isNetworkFailure;

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

    /** The track's id, null for {@link Kind#EMPTY}. */
    @Nullable final String mediaId;

    /**
     * Tells covers apart: {@link RecentItem#coverKey} of the {@link ArtworkLoader#key}. Null: no
     * cover.
     */
    @Nullable final String artworkKey;

    /** Shows Pause rather than Play. */
    final boolean playing;

    final boolean canSkip;

    /** The session the buttons go to, null for the one PlaybackService picks. */
    @Nullable final String sessionId;

    State(
        Kind kind,
        @Nullable String mediaId,
        @Nullable String title,
        @Nullable String artist,
        @Nullable String album,
        @Nullable Uri artworkUri,
        @Nullable String artworkKey,
        boolean playing,
        boolean canSkip,
        @Nullable String sessionId) {
      this.kind = kind;
      this.mediaId = mediaId;
      this.title = title;
      this.artist = artist;
      this.album = album;
      this.artworkUri = artworkUri;
      this.artworkKey = artworkKey;
      this.playing = playing;
      this.canSkip = canSkip;
      this.sessionId = sessionId;
    }

    static final State EMPTY =
        new State(Kind.EMPTY, null, null, null, null, null, null, false, false, null);

    /**
     * The recent track, with the cover saved for it; [playing] while the stand-in waits for the app
     * to resume it.
     */
    static State recent(Context context, boolean playing, @Nullable String sessionId) {
      MediaItem item = RecentItem.load(context);
      if (item == null) return EMPTY;
      MediaMetadata metadata = item.mediaMetadata;
      return new State(
          Kind.RECENT,
          item.mediaId,
          string(metadata.title),
          string(metadata.artist),
          string(metadata.albumTitle),
          null,
          RecentItem.savedCoverKey(context),
          playing,
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
      MediaItem item = player.getCurrentMediaItem();
      MediaMetadata metadata = player.getMediaMetadata();
      Uri artworkUri = metadata.artworkUri;
      String artworkKey =
          artworkUri != null ? RecentItem.coverKey(session.artwork.key(artworkUri)) : null;
      // Also while buffering after Play (playWhenReady): the service is in the foreground then
      boolean playing = !Util.shouldShowPlayButton(player);
      return new State(
          Kind.PLAYER,
          item.mediaId,
          string(metadata.title),
          string(metadata.artist),
          string(metadata.albumTitle),
          artworkKey != null ? artworkUri : null,
          artworkKey,
          playing,
          // Only while playing, see skip()
          playing && player.isCommandAvailable(Player.COMMAND_SEEK_TO_NEXT),
          sessionId);
    }

    @Override
    public boolean equals(Object o) {
      if (!(o instanceof State)) return false;
      State other = (State) o;
      return kind == other.kind
          && Objects.equals(mediaId, other.mediaId)
          && Objects.equals(title, other.title)
          && Objects.equals(artist, other.artist)
          && Objects.equals(album, other.album)
          && Objects.equals(artworkUri, other.artworkUri)
          && Objects.equals(artworkKey, other.artworkKey)
          && playing == other.playing
          && canSkip == other.canSkip
          && Objects.equals(sessionId, other.sessionId);
    }

    @Override
    public int hashCode() {
      return Objects.hash(
          kind,
          mediaId,
          title,
          artist,
          album,
          artworkUri,
          artworkKey,
          playing,
          canSkip,
          sessionId);
    }
  }

  /** A loaded cover, scaled down, and the {@link State#artworkKey} it was loaded for. */
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
    if (!Objects.equals(retryKey, state.artworkKey)) stopWaiting(context);
    render(context, widgetIds(context));
    if (cover != null) {
      // Kept from the track before (an album)
      saveCover(context, state);
    } else if (state.kind == State.Kind.RECENT && state.artworkKey != null) {
      loadSavedCover(context, state.artworkKey);
    } else if (state.artworkUri != null && shownSession != null) {
      loadCover(context, shownSession, state.artworkUri, state.artworkKey, false);
    }
  }

  /** Shows [bitmap], loaded for [key], if that's still the cover shown. On the main thread. */
  private static void showCover(Context context, String key, Bitmap bitmap) {
    if (shown == null || !key.equals(shown.artworkKey)) return;
    cover = new Cover(key, bitmap);
    stopWaiting(context);
    render(context, widgetIds(context));
    saveCover(context, shown);
  }

  /** Keeps the cover of a track of the app's player for when it's the recent track. */
  private static void saveCover(Context context, State state) {
    if (state.kind != State.Kind.PLAYER || cover == null || state.mediaId == null) return;
    if (!cover.key.equals(state.artworkKey)) return;
    RecentItem.saveCover(context, state.mediaId, cover.key, cover.bitmap);
  }

  /** Loads the cover saved for the recent track, see {@link RecentItem#saveCover}. */
  private static void loadSavedCover(Context context, String key) {
    RecentItem.loadCover(
        context,
        key,
        bitmap -> {
          // The placeholder stays if it can't be read
          if (bitmap != null) handler.post(() -> showCover(context, key, bitmap));
        });
  }

  /**
   * Loads the cover through the session's bitmap loader, which caches the last one: the
   * notification usually loaded it already. Also offline, see {@link ArtworkLoader}. [retry]
   * loads it through the {@link ArtworkLoader} itself: the session's loader keeps a failed load
   * too, and would hand it out again.
   */
  private static void loadCover(
      Context context, PlayerSession session, Uri uri, String key, boolean retry) {
    ListenableFuture<Bitmap> future;
    try {
      future =
          retry
              ? session.artwork.loadBitmap(uri)
              : session.session.getBitmapLoader().loadBitmap(uri);
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
            handler.post(() -> showCover(context, key, scaled));
          }

          @Override
          public void onFailure(Throwable t) {
            // The placeholder stays
            Log.w(TAG, "Could not load the cover: " + t);
            handler.post(() -> coverFailed(context, key, t));
          }
        },
        MoreExecutors.directExecutor());
  }

  /**
   * The cover [key] of the app's player couldn't be loaded ([failure]): if that was the network,
   * it's loaded again when a network is back, up to {@link #MAX_RETRIES} times per cover. Not after
   * the server answered (an error status or document): the same request would fail the same way,
   * and failed logins add up (see "Rejected credentials" in docs/DEVELOPMENT.md). On the main
   * thread.
   */
  private static void coverFailed(Context context, String key, Throwable failure) {
    if (shown == null || !key.equals(shown.artworkKey) || cover != null) return;
    if (!retryable.test(failure)) {
      if (key.equals(retryKey)) stopWaiting(context);
      return;
    }
    if (!key.equals(retryKey)) {
      stopWaiting(context);
      retryKey = key;
      retries = 0;
    }
    if (retries >= MAX_RETRIES) {
      // Once, not on every redraw of the same cover after
      if (retryCallback != null) Log.i(TAG, "Cover not loaded again: tried " + retries + " times");
      stopWaiting(context);
      return;
    }
    waitForNetwork(context);
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

  /** Registers {@link #retryCallback}, unless it is already. */
  private static void waitForNetwork(Context context) {
    if (retryCallback != null) return;
    Context app = context.getApplicationContext();
    ConnectivityManager connectivity = app.getSystemService(ConnectivityManager.class);
    // Registering reports the network there is now, if any: it didn't come back, a load just
    // failed on it. A later one did.
    skipCurrentNetwork = isOnline(connectivity);
    ConnectivityManager.NetworkCallback[] callback = new ConnectivityManager.NetworkCallback[1];
    callback[0] =
        new NetworkMonitor.Callback(
            // On a thread of ConnectivityManager's
            () -> handler.post(() -> networkAvailable(app, callback[0])));
    retryCallback = callback[0];
    try {
      connectivity.registerDefaultNetworkCallback(retryCallback);
    } catch (RuntimeException e) {
      // E.g. too many callbacks registered by the app: no retry then
      Log.w(TAG, "Could not wait for the network", e);
      retryCallback = null;
    }
  }

  private static boolean isOnline(ConnectivityManager connectivity) {
    Network network = connectivity.getActiveNetwork();
    NetworkCapabilities capabilities =
        network != null ? connectivity.getNetworkCapabilities(network) : null;
    return capabilities != null
        && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
  }

  /** A network is there: loads {@link #retryKey} again if it's still the cover missing. */
  private static void networkAvailable(Context context, ConnectivityManager.NetworkCallback from) {
    if (from != retryCallback) return;
    if (skipCurrentNetwork) {
      skipCurrentNetwork = false;
      return;
    }
    State state = shown;
    PlayerSession session = shownSession;
    if (state == null
        || session == null
        || cover != null
        || state.artworkUri == null
        || !Objects.equals(retryKey, state.artworkKey)) {
      stopWaiting(context);
      return;
    }
    retries++;
    Log.i(TAG, "Network back: loading the cover again (" + retries + ")");
    loadCover(context, session, state.artworkUri, retryKey, true);
  }

  /** Unregisters {@link #retryCallback}. The tries made for {@link #retryKey} still count. */
  private static void stopWaiting(Context context) {
    if (retryCallback == null) return;
    ConnectivityManager.NetworkCallback callback = retryCallback;
    retryCallback = null;
    skipCurrentNetwork = false;
    try {
      context
          .getApplicationContext()
          .getSystemService(ConnectivityManager.class)
          .unregisterNetworkCallback(callback);
    } catch (RuntimeException e) {
      Log.w(TAG, "Could not stop waiting for the network", e);
    }
  }

  @VisibleForTesting
  static boolean waitsForNetwork() {
    return retryCallback != null;
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
   * Next goes to this receiver, which passes it to the player (and on to Dart), rather
   * than to {@link PlaybackService} as media buttons. Only Play may start the service from the
   * background, as a foreground service; a plain start is refused while it's stopped (after a stop,
   * or about 10 minutes after a pause), and Media3 only puts it in the foreground for Play. It's
   * only enabled while playing, see {@link #skip}.
   */
  private static PendingIntent skipIntent(Context context, String action) {
    Intent intent = new Intent(context, PlayerWidget.class).setAction(action);
    return PendingIntent.getBroadcast(
        context, 0, intent, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
  }

  /**
   * Next on a widget: moves the app's player (through {@link SessionPlayer}, to Dart,
   * as any controller would), if it's the one shown and can skip.
   *
   * <p>Only while it plays. A skip starts playback (in Dart), which needs the service in the
   * foreground; it is while playing. Paused, the service may be stopped or out of the foreground,
   * and this receiver may not start it: playback would run without a foreground service, which
   * Android freezes. Bluetooth buttons don't have that problem, as Android lets the app start it for
   * a media button.
   */
  private static void skip() {
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
    if (player.isCommandAvailable(Player.COMMAND_SEEK_TO_NEXT)) player.seekToNext();
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
    if (ACTION_NEXT.equals(action)) {
      // A tap on a widget drawn by an earlier process starts a new one: draw it as it is now
      refresh(context);
      skip();
      return;
    }
    super.onReceive(context, intent);
  }

  /** A widget was added, the device started, or the app was updated. */
  @Override
  public void onUpdate(Context context, AppWidgetManager manager, int[] ids) {
    // The first time in this process: draws every widget, and loads the cover
    if (shown == null) update(context.getApplicationContext());
    else render(context, ids);
  }

  /** Resized: before Android 12, the layout is picked here. */
  @Override
  public void onAppWidgetOptionsChanged(
      Context context, AppWidgetManager manager, int id, Bundle options) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) render(context, new int[] {id});
  }

  @VisibleForTesting
  static void reset(Context context) {
    stopWaiting(context);
    retryKey = null;
    retries = 0;
    retryable = PlayerWidget::isNetworkFailure;
    shownSession = null;
    shown = null;
    cover = null;
  }
}
