package com.example.voidweaver.player;

import android.content.Context;
import androidx.annotation.NonNull;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.HashMap;
import java.util.Map;

/** Creates and releases {@link PlaylistPlayer}s, one per Dart {@code VoidweaverPlayer}. */
public class VoidweaverPlayerPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
  private final Map<String, PlaylistPlayer> players = new HashMap<>();
  private MethodChannel channel;
  private Context context;
  private BinaryMessenger messenger;

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    messenger = binding.getBinaryMessenger();
    channel = new MethodChannel(messenger, "voidweaver_player");
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    String id = call.argument("id");
    switch (call.method) {
      case "create":
        if (!players.containsKey(id)) {
          players.put(id, new PlaylistPlayer(context, messenger, id));
        }
        result.success(null);
        break;
      case "dispose":
        PlaylistPlayer player = players.remove(id);
        if (player != null) player.release();
        result.success(null);
        break;
      default:
        result.notImplemented();
    }
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    for (PlaylistPlayer player : players.values()) {
      player.release();
    }
    players.clear();
    channel.setMethodCallHandler(null);
  }
}
