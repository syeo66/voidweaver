package com.example.voidweaver.player;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import androidx.annotation.NonNull;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Creates and releases {@link PlaylistPlayer}s, one per Dart {@code VoidweaverPlayer}, and gives
 * Dart access to the {@link MediaCache}.
 */
public class VoidweaverPlayerPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
  private final Map<String, PlaylistPlayer> players = new HashMap<>();
  private final Handler mainHandler = new Handler(Looper.getMainLooper());
  // Downloads run one at a time, apart from the quick cache reads, which mustn't wait for them
  private ExecutorService downloads;
  private ExecutorService reads;
  private MethodChannel channel;
  private Context context;
  private BinaryMessenger messenger;

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    messenger = binding.getBinaryMessenger();
    downloads = Executors.newSingleThreadExecutor();
    reads = Executors.newSingleThreadExecutor();
    channel = new MethodChannel(messenger, "voidweaver_player");
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    switch (call.method) {
      case "create":
        {
          String id = call.argument("id");
          if (!players.containsKey(id)) {
            players.put(id, new PlaylistPlayer(context, messenger, id));
          }
          result.success(null);
          break;
        }
      case "dispose":
        {
          PlaylistPlayer player = players.remove((String) call.argument("id"));
          if (player != null) player.release();
          result.success(null);
          break;
        }
      case "cache.prefetch":
        run(
            downloads,
            result,
            () -> {
              MediaCache.prefetch(context, call.argument("key"), call.argument("uri"));
              return null;
            });
        break;
      case "cache.cachedKeys":
        {
          List<String> keys = call.argument("keys");
          run(reads, result, () -> MediaCache.cachedKeys(context, keys));
          break;
        }
      case "cache.readHead":
        run(
            reads,
            result,
            () ->
                MediaCache.readHead(
                    context, call.argument("key"), ((Number) call.argument("length")).intValue()));
        break;
      case "cache.size":
        run(reads, result, () -> MediaCache.sizeInBytes(context));
        break;
      case "cache.clear":
        run(
            reads,
            result,
            () -> {
              MediaCache.clear(context);
              return null;
            });
        break;
      default:
        result.notImplemented();
    }
  }

  /** Runs [task] on [executor] and replies with its result on the main thread. */
  private void run(ExecutorService executor, MethodChannel.Result result, Callable<?> task) {
    executor.execute(
        () -> {
          try {
            Object value = task.call();
            mainHandler.post(() -> result.success(value));
          } catch (Exception e) {
            mainHandler.post(() -> result.error("error", e.toString(), null));
          }
        });
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    for (PlaylistPlayer player : players.values()) {
      player.release();
    }
    players.clear();
    // Interrupts a running download; what was downloaded so far stays cached
    downloads.shutdownNow();
    reads.shutdownNow();
    channel.setMethodCallHandler(null);
  }
}
