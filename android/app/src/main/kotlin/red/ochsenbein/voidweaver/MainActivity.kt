package red.ochsenbein.voidweaver

import android.app.NotificationManager
import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.view.KeyEvent
import com.example.voidweaver.player.AppEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

// Audio focus is handled by the player's ExoPlayer (packages/voidweaver_player).
// Requesting it here as well would register a second focus listener that
// competes with the player's and breaks resuming after interruptions.
class MainActivity : FlutterActivity() {
    // The engine outlives the activity: playlist logic, scrobbling and
    // downloads run in Dart and have to keep going while the app is in the
    // background without an activity (e.g. after it was swiped away while
    // playing). A new activity attaches to the same engine, also to one the
    // playback service started to resume playback.
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        AppEngine.getOrStart(context)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Media3 posts the media notification on its own channel. The one
        // audio_service used is no longer needed.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java)
                .deleteNotificationChannel("com.voidweaver.audio")
        }
    }

    // Media keys go to the media session, as when the app isn't focused.
    // Once a text field had focus (e.g. after logging in), the FlutterView
    // keeps the view focus and claims every key, handing unhandled ones back
    // only within the app, so Android never passes them on to the session
    // and media buttons (also Bluetooth) did nothing while the app was shown.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode in MEDIA_KEYS) {
            getSystemService(AudioManager::class.java).dispatchMediaKeyEvent(event)
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    private companion object {
        val MEDIA_KEYS = setOf(
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_HEADSETHOOK,
            KeyEvent.KEYCODE_MEDIA_STOP,
            KeyEvent.KEYCODE_MEDIA_NEXT,
            KeyEvent.KEYCODE_MEDIA_PREVIOUS,
            KeyEvent.KEYCODE_MEDIA_REWIND,
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD,
        )
    }
}
