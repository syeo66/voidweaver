package red.ochsenbein.voidweaver.player;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import androidx.annotation.Nullable;
import androidx.media3.common.Player;
import androidx.media3.session.MediaLibraryService;
import androidx.media3.session.MediaSession;
import java.util.LinkedHashSet;
import java.util.Set;

/**
 * Hosts the media sessions of the {@link PlaylistPlayer}s. Media3 shows the media notification for
 * them and keeps the service in the foreground while one plays.
 *
 * <p>Sessions are created by the players, not by the service, so they're registered here and added
 * to the service once it runs. Everything runs on the main thread.
 *
 * <p>After the app was closed (the process ended), a Play media button (also Bluetooth) reaches
 * Media3's {@code MediaButtonReceiver}, which starts this service, and System UI's resumption
 * controls bind to it. There is no player yet, so a {@link ResumePlayer} answers them, and starts
 * the app's engine. Once Dart has restored its queue, it asks {@link #takeResumeRequest()} and
 * plays.
 *
 * <p>The app's player then takes over the stand-in's session ({@link #claimResumeSession}) rather
 * than replacing it with its own. Android sends media buttons to the session of the app that played
 * last, and when that session is released it doesn't pass them on to another session of the app:
 * media buttons (and Bluetooth) then only reached {@code MediaButtonReceiver}, which ignores all
 * but Play while the app runs.
 *
 * <p>It's a library service so System UI can ask it for the recent track ({@link PlayerSession}).
 * Without that, System UI dropped the media controls once the app had been paused for about 10
 * minutes, instead of showing resumption controls.
 */
public final class PlaybackService extends MediaLibraryService {
  private static final String TAG = "PlaybackService";

  /** How long the stand-in waits for the app's player to play before giving up. */
  private static final long RESUME_TIMEOUT_MS = 60_000;

  private static final Set<MediaLibrarySession> sessions = new LinkedHashSet<>();
  @Nullable private static PlaybackService instance;

  /** The stand-in's session, until the app's player took it over or it was released. */
  @Nullable private PlayerSession resumeSession;

  @Nullable private ResumePlayer resumePlayer;

  /** The app's player that claimed resumeSession, and takes it over in {@link #handOver()}. */
  @Nullable private Player successor;

  private final Handler handler = new Handler(Looper.getMainLooper());
  private final Runnable resumeTimeout = this::handOver;

  static void register(Context context, MediaLibrarySession session) {
    sessions.add(session);
    if (instance != null) {
      instance.addSession(session);
    } else {
      start(context);
    }
  }

  static void unregister(MediaLibrarySession session) {
    sessions.remove(session);
    if (instance != null) {
      if (instance.resumeSession != null && instance.resumeSession.session == session) {
        // Released by the player that claimed it, before it took it over
        instance.handler.removeCallbacks(instance.resumeTimeout);
        instance.resumeSession = null;
        instance.resumePlayer = null;
        instance.successor = null;
      }
      instance.removeSession(session);
      if (sessions.isEmpty() && instance.resumeSession == null) instance.stopSelf();
    }
  }

  /**
   * The stand-in's session, if the app was started to resume playback (or System UI bound to the
   * service before the app ran), for the app's [player]. The stand-in stays its player, keeping
   * the notification and the foreground service, until the app's player plays, the app answers
   * that no resume is pending, or the timeout; then [player] takes over. Null if there's no
   * stand-in, or another player claimed it.
   */
  @Nullable
  static PlayerSession claimResumeSession(Player player) {
    if (instance == null || instance.resumeSession == null || instance.successor != null) {
      return null;
    }
    instance.successor = player;
    sessions.add(instance.resumeSession.session);
    return instance.resumeSession;
  }

  /**
   * Starts the service again if it stopped, e.g. after the app was removed from the recent apps
   * while paused. Called before playback starts.
   */
  static void ensureStarted(Context context) {
    if (instance == null && !sessions.isEmpty()) start(context);
  }

  /**
   * Whether the app was started to resume playback (Play pressed while it wasn't running), and it
   * should now play. Answers true once; the stand-in stays until the app's player plays.
   */
  static boolean takeResumeRequest() {
    if (instance == null || instance.resumePlayer == null) return false;
    boolean requested = instance.resumePlayer.isResumeRequested();
    if (!requested) instance.handOver();
    return requested;
  }

  /** The app's player plays: it takes over from the stand-in, see {@link ResumePlayer}. */
  static void onPlaying() {
    if (instance != null) instance.handOver();
  }

  /** Opens the app, for tapping the notification. */
  @Nullable
  static PendingIntent sessionActivity(Context context) {
    Intent launchIntent =
        context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
    if (launchIntent == null) return null;
    return PendingIntent.getActivity(
        context, 0, launchIntent, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
  }

  private static void start(Context context) {
    try {
      context.startService(new Intent(context, PlaybackService.class));
    } catch (IllegalStateException e) {
      // Not allowed while the app is in the background
      Log.w(TAG, "Could not start the playback service", e);
    }
  }

  @Override
  public void onCreate() {
    super.onCreate();
    instance = this;
    // The session is only idle once playback was stopped (SessionPlayer shows a failed load as
    // paused), and a stop ends the notification and the foreground service
    setShowNotificationForIdlePlayer(SHOW_NOTIFICATION_FOR_IDLE_PLAYER_NEVER);
    for (MediaLibrarySession session : sessions) {
      addSession(session);
    }
  }

  @Nullable
  @Override
  public MediaLibrarySession onGetSession(MediaSession.ControllerInfo controllerInfo) {
    MediaLibrarySession current = null;
    for (MediaLibrarySession session : sessions) {
      current = session;
    }
    if (current != null) return current;
    // Started for a media button (or by the system UI) while the app isn't running
    if (resumeSession == null) {
      resumePlayer = new ResumePlayer(Looper.getMainLooper(), appName(), this::onResumeRequested);
      resumeSession = PlayerSession.create(this, "resume", resumePlayer);
    }
    return resumeSession.session;
  }

  private void onResumeRequested() {
    handler.removeCallbacks(resumeTimeout);
    handler.postDelayed(resumeTimeout, RESUME_TIMEOUT_MS);
    // Runs the app's main(), which restores the queue and asks takeResumeRequest()
    AppEngine.getOrStart(this);
  }

  /**
   * Ends the stand-in: the player that claimed its session takes over, keeping the session that
   * gets the media buttons. If none did, the session is released.
   */
  private void handOver() {
    handler.removeCallbacks(resumeTimeout);
    if (resumeSession == null) return;
    PlayerSession stoodIn = resumeSession;
    ResumePlayer stoodInPlayer = resumePlayer;
    Player next = successor;
    resumeSession = null;
    resumePlayer = null;
    successor = null;
    if (next != null) {
      stoodIn.session.setPlayer(next);
    } else {
      removeSession(stoodIn.session);
      stoodIn.session.release();
    }
    if (stoodInPlayer != null) stoodInPlayer.release();
    if (sessions.isEmpty()) stopSelf();
  }

  private String appName() {
    ApplicationInfo info = getApplicationInfo();
    return getPackageManager().getApplicationLabel(info).toString();
  }

  @Override
  public void onDestroy() {
    // A claimed session belongs to the app's player and outlives the service
    handOver();
    instance = null;
    super.onDestroy();
  }
}
