package red.ochsenbein.voidweaver

import android.app.NotificationManager
import android.content.Context
import android.os.Build
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
}
