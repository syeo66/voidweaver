package com.example.voidweaver.player;

import android.content.Context;
import android.content.Intent;
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
 */
public final class PlaybackService extends MediaSessionService {
  private static final String TAG = "PlaybackService";

  private static final Set<MediaSession> sessions = new LinkedHashSet<>();
  @Nullable private static PlaybackService instance;

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
      if (sessions.isEmpty()) instance.stopSelf();
    }
  }

  /**
   * Starts the service again if it stopped, e.g. after the app was removed from the recent apps
   * while paused. Called before playback starts.
   */
  static void ensureStarted(Context context) {
    if (instance == null && !sessions.isEmpty()) start(context);
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
    return current;
  }

  @Override
  public void onDestroy() {
    instance = null;
    super.onDestroy();
  }
}
