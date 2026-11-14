package red.ochsenbein.voidweaver;

import android.content.Context;
import android.media.AudioManager;
import android.view.KeyEvent;
import androidx.annotation.NonNull;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import red.ochsenbein.voidweaver.player.AppEngine;

// Audio focus is handled by the player's ExoPlayer (packages/voidweaver_player).
// Requesting it here as well would register a second focus listener that
// competes with the player's and breaks resuming after interruptions.
public class MainActivity extends FlutterActivity {
  // The engine outlives the activity: playlist logic, scrobbling and
  // downloads run in Dart and have to keep going while the app is in the
  // background without an activity (e.g. after it was swiped away while
  // playing). A new activity attaches to the same engine, also to one the
  // playback service started to resume playback.
  @Override
  public FlutterEngine provideFlutterEngine(@NonNull Context context) {
    return AppEngine.getOrStart(context);
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
