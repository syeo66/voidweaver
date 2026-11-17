package red.ochsenbein.voidweaver;

import android.content.Context;
import android.content.Intent;
import android.media.AudioManager;
import android.os.Bundle;
import android.util.Log;
import android.view.KeyEvent;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import java.util.concurrent.atomic.AtomicBoolean;
import red.ochsenbein.voidweaver.player.AppEngine;

// Audio focus is handled by the player's ExoPlayer (packages/voidweaver_player).
// Requesting it here as well would register a second focus listener that
// competes with the player's and breaks resuming after interruptions.
public class MainActivity extends FlutterActivity {
  private static final String TAG = "VoidweaverShortcut";

  /** The launcher shortcut's action (res/xml/shortcuts.xml). Pinned shortcuts use it: keep it. */
  static final String ACTION_PLAY_RANDOM = "red.ochsenbein.voidweaver.action.PLAY_RANDOM";

  // A tap on the Random shortcut that Dart hasn't taken yet. Static: the
  // engine (and Dart) outlives the activity that got the tap.
  private static final AtomicBoolean randomRequested = new AtomicBoolean();

  // The engine outlives the activity: playlist logic, scrobbling and
  // downloads run in Dart and have to keep going while the app is in the
  // background without an activity (e.g. after it was swiped away while
  // playing). A new activity attaches to the same engine, also to one the
  // playback service started to resume playback.
  @Override
  public FlutterEngine provideFlutterEngine(@NonNull Context context) {
    return AppEngine.getOrStart(context);
  }

  // Dart asks for a shortcut tap once it's ready and whenever the app comes
  // to the front (the activity resumes after onCreate and onNewIntent), so
  // nothing is pushed. Called for every activity that attaches to the cached
  // engine; the handler replaces the previous one and holds no activity, so
  // it stays and answers after the activity is gone. Only an engine that no
  // activity has attached to yet (started to resume playback) has none, and
  // then there's no tap to answer for either.
  @Override
  public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
    super.configureFlutterEngine(flutterEngine);
    new MethodChannel(flutterEngine.getDartExecutor(), "voidweaver/shortcuts")
        .setMethodCallHandler(
            (call, result) -> {
              if ("takeRandomRequest".equals(call.method)) {
                result.success(randomRequested.getAndSet(false));
              } else {
                result.notImplemented();
              }
            });
  }

  @Override
  protected void onCreate(@Nullable Bundle savedInstanceState) {
    // Before super: it attaches the engine, and Dart may ask right after
    noteShortcut(getIntent(), savedInstanceState != null);
    super.onCreate(savedInstanceState);
  }

  @Override
  protected void onNewIntent(@NonNull Intent intent) {
    super.onNewIntent(intent);
    noteShortcut(intent, false);
  }

  // Launchers start a static shortcut with NEW_TASK | CLEAR_TASK, so a tap
  // usually recreates the activity (onCreate); onNewIntent covers a launcher
  // that doesn't. An activity recreated from saved state, or reopened from
  // the recents, gets the intent it was first started with again: that tap
  // was handled back then and mustn't start random a second time.
  private static void noteShortcut(@Nullable Intent intent, boolean restored) {
    if (intent == null || !ACTION_PLAY_RANDOM.equals(intent.getAction())) return;
    boolean fromHistory = (intent.getFlags() & Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0;
    if (restored || fromHistory) {
      Log.i(TAG, "Redelivered shortcut ignored, flags 0x" + Integer.toHexString(intent.getFlags()));
      return;
    }
    Log.i(TAG, "Random shortcut, flags 0x" + Integer.toHexString(intent.getFlags()));
    randomRequested.set(true);
  }

  // Media keys go to the media session, as when the app isn't focused.
  // Once a text field had focus (e.g. after logging in), the FlutterView
  // keeps the view focus and claims every key, handing unhandled ones back
  // only within the app, so Android never passes them on to the session
  // and media buttons (also Bluetooth) did nothing while the app was shown.
  @Override
  public boolean dispatchKeyEvent(KeyEvent event) {
    if (isMediaKey(event.getKeyCode())) {
      getSystemService(AudioManager.class).dispatchMediaKeyEvent(event);
      return true;
    }
    return super.dispatchKeyEvent(event);
  }

  private static boolean isMediaKey(int keyCode) {
    switch (keyCode) {
      case KeyEvent.KEYCODE_MEDIA_PLAY:
      case KeyEvent.KEYCODE_MEDIA_PAUSE:
      case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE:
      case KeyEvent.KEYCODE_HEADSETHOOK:
      case KeyEvent.KEYCODE_MEDIA_STOP:
      case KeyEvent.KEYCODE_MEDIA_NEXT:
      case KeyEvent.KEYCODE_MEDIA_PREVIOUS:
      case KeyEvent.KEYCODE_MEDIA_REWIND:
      case KeyEvent.KEYCODE_MEDIA_FAST_FORWARD:
        return true;
      default:
        return false;
    }
  }
}
