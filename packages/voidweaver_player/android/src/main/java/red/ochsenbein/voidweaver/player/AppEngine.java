package red.ochsenbein.voidweaver.player;

import android.content.Context;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.FlutterEngineCache;
import io.flutter.embedding.engine.dart.DartExecutor;

/**
 * The app's one Flutter engine, kept in {@link FlutterEngineCache} so it outlives the activity:
 * playlist logic, scrobbling and downloads run in Dart. The activity attaches to it, and {@link
 * PlaybackService} starts it without an activity to resume playback after the app was closed.
 */
public final class AppEngine {
  private static final String ID = "main";

  private AppEngine() {}

  /** The running engine, started (running the app's {@code main()}) if there is none. */
  public static FlutterEngine getOrStart(Context context) {
    FlutterEngineCache cache = FlutterEngineCache.getInstance();
    FlutterEngine engine = cache.get(ID);
    if (engine == null) {
      engine = new FlutterEngine(context.getApplicationContext());
      engine.getDartExecutor().executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault());
      cache.put(ID, engine);
    }
    return engine;
  }
}
