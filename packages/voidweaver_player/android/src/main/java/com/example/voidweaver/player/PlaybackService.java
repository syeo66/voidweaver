package com.example.voidweaver.player;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import androidx.annotation.Nullable;
import androidx.media3.session.MediaSession;
import androidx.media3.session.MediaSessionService;
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
 * Media3's {@code MediaButtonReceiver}, which starts this service. There is no player yet, so a
 * {@link ResumePlayer} answers it, and starts the app's engine. Once Dart has restored its queue,
 * it asks {@link #takeResumeRequest()} and plays; the stand-in goes once the app's player plays.
 */
public final class PlaybackService extends MediaSessionService {
  private static final String TAG = "PlaybackService";

  /** How long the stand-in waits for the app's player to play before giving up. */
  private static final long RESUME_TIMEOUT_MS = 60_000;

  private static final Set<MediaSession> sessions = new LinkedHashSet<>();
  @Nullable private static PlaybackService instance;

  @Nullable private MediaSession resumeSession;
  @Nullable private ResumePlayer resumePlayer;
  private final Handler handler = new Handler(Looper.getMainLooper());
  private final Runnable resumeTimeout = this::releaseResumeSession;

  static void register(Context context, MediaSession session) {
    sessions.add(session);
    if (instance != null) {
      instance.addSession(session);
    } else {
      start(context);
    }
  }

  static void unregister(MediaSession session) {
    sessions.remove(session);
    if (instance != null) {
      instance.removeSession(session);
      if (sessions.isEmpty() && instance.resumeSession == null) instance.stopSelf();
    }
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
    if (!requested) instance.releaseResumeSession();
    return requested;
  }

  /** The app's player plays: it takes over from the stand-in, see {@link ResumePlayer}. */
  static void onPlaying() {
    if (instance != null) instance.releaseResumeSession();
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
    for (MediaSession session : sessions) {
      addSession(session);
    }
  }

  @Nullable
  @Override
  public MediaSession onGetSession(MediaSession.ControllerInfo controllerInfo) {
    MediaSession current = null;
    for (MediaSession session : sessions) {
      current = session;
    }
    if (current != null) return current;
    // Started for a media button (or by the system UI) while the app isn't running
    if (resumeSession == null) {
      resumePlayer = new ResumePlayer(Looper.getMainLooper(), appName(), this::onResumeRequested);
      MediaSession.Builder builder = new MediaSession.Builder(this, resumePlayer).setId("resume");
      PendingIntent activity = sessionActivity(this);
      if (activity != null) builder.setSessionActivity(activity);
      resumeSession = builder.build();
    }
    return resumeSession;
  }

  private void onResumeRequested() {
    handler.removeCallbacks(resumeTimeout);
    handler.postDelayed(resumeTimeout, RESUME_TIMEOUT_MS);
    // Runs the app's main(), which restores the queue and asks takeResumeRequest()
    AppEngine.getOrStart(this);
  }

  private void releaseResumeSession() {
    handler.removeCallbacks(resumeTimeout);
    if (resumeSession == null) return;
    removeSession(resumeSession);
    resumeSession.release();
    resumeSession = null;
    resumePlayer = null;
    if (sessions.isEmpty()) stopSelf();
  }

  private String appName() {
    ApplicationInfo info = getApplicationInfo();
    return getPackageManager().getApplicationLabel(info).toString();
  }

  @Override
  public void onDestroy() {
    releaseResumeSession();
    instance = null;
    super.onDestroy();
  }
}
