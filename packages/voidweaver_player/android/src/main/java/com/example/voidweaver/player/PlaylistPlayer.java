package com.example.voidweaver.player;

import android.content.Context;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.Timeline;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.datasource.DefaultDataSource;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlaybackException;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.DefaultAudioSink;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import androidx.media3.extractor.DefaultExtractorsFactory;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * One ExoPlayer with a playlist, controlled from Dart over {@code voidweaver_player/<id>} and
 * reporting its state on {@code voidweaver_player/<id>/events}.
 *
 * <p>Every method replies with a state snapshot, which Dart applies before the call completes, so
 * the Dart side never sees a state from before its own call. {@code setAudioSources} replies once
 * the start item is ready (or fails, or is replaced by another call); {@code seek} once the target
 * is ready or has failed.
 */
final class PlaylistPlayer implements MethodChannel.MethodCallHandler, Player.Listener {
  // Matches ProcessingState in Dart
  private static final int STATE_IDLE = 0;
  private static final int STATE_BUFFERING = 2;
  private static final int STATE_READY = 3;
  private static final int STATE_COMPLETED = 4;

  private static final long POSITION_UPDATE_INTERVAL_MS = 200;

  private final MethodChannel methodChannel;
  private final EventChannel eventChannel;
  private final GainAudioProcessor gainProcessor = new GainAudioProcessor();
  private final ExoPlayer player;
  private final Handler handler = new Handler(Looper.getMainLooper());
  private final Runnable positionUpdate = this::onPositionUpdate;

  @Nullable private EventChannel.EventSink eventSink;
  @Nullable private MethodChannel.Result pendingLoad;
  @Nullable private MethodChannel.Result pendingSeek;

  PlaylistPlayer(Context context, BinaryMessenger messenger, String id) {
    DefaultRenderersFactory renderersFactory =
        new DefaultRenderersFactory(context) {
          @Override
          protected AudioSink buildAudioSink(
              Context context, boolean enableFloatOutput, boolean enableAudioOutputPlaybackParams) {
            return new DefaultAudioSink.Builder(context)
                .setEnableFloatOutput(enableFloatOutput)
                .setEnableAudioOutputPlaybackParameters(enableAudioOutputPlaybackParams)
                .setAudioProcessors(new AudioProcessor[] {gainProcessor})
                .build();
          }
        };
    DefaultHttpDataSource.Factory httpFactory =
        new DefaultHttpDataSource.Factory()
            .setUserAgent("voidweaver")
            .setAllowCrossProtocolRedirects(true);
    DefaultExtractorsFactory extractorsFactory =
        new DefaultExtractorsFactory().setConstantBitrateSeekingEnabled(true);
    player =
        new ExoPlayer.Builder(context, renderersFactory)
            .setMediaSourceFactory(
                new DefaultMediaSourceFactory(
                    new DefaultDataSource.Factory(context, httpFactory), extractorsFactory))
            // ExoPlayer requests audio focus, pauses for interruptions and resumes after
            // transient ones. Nothing else in the app may request focus.
            .setAudioAttributes(
                new AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build(),
                /* handleAudioFocus= */ true)
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build();
    player.addListener(this);

    methodChannel = new MethodChannel(messenger, "voidweaver_player/" + id);
    methodChannel.setMethodCallHandler(this);
    eventChannel = new EventChannel(messenger, "voidweaver_player/" + id + "/events");
    eventChannel.setStreamHandler(
        new EventChannel.StreamHandler() {
          @Override
          public void onListen(Object arguments, EventChannel.EventSink events) {
            eventSink = events;
          }

          @Override
          public void onCancel(Object arguments) {
            eventSink = null;
          }
        });
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    try {
      switch (call.method) {
        case "setAudioSources":
          setAudioSources(call, result);
          return;
        case "insertAudioSource":
          {
            Map<?, ?> source = call.argument("source");
            player.addMediaItem(intArg(call, "index"), mediaItem(source));
            break;
          }
        case "removeAudioSourceAt":
          player.removeMediaItem(intArg(call, "index"));
          break;
        case "setGain":
          gainProcessor.setGain(call.argument("id"), ((Number) call.argument("gain")).floatValue());
          break;
        case "play":
          player.play();
          break;
        case "pause":
          player.pause();
          break;
        case "stop":
          interruptLoad();
          completeSeek();
          player.pause();
          player.stop();
          break;
        case "seek":
          seek(call, result);
          return;
        default:
          result.notImplemented();
          return;
      }
      result.success(snapshot());
    } catch (RuntimeException e) {
      result.error("error", e.toString(), null);
    }
  }

  private static int intArg(MethodCall call, String key) {
    return ((Number) call.argument(key)).intValue();
  }

  private MediaItem mediaItem(Map<?, ?> source) {
    String id = (String) source.get("id");
    gainProcessor.setGain(id, ((Number) source.get("gain")).floatValue());
    return new MediaItem.Builder().setMediaId(id).setUri(Uri.parse((String) source.get("uri"))).build();
  }

  private void setAudioSources(MethodCall call, MethodChannel.Result result) {
    interruptLoad();
    completeSeek();
    gainProcessor.clearGains();
    List<?> sources = call.argument("sources");
    List<MediaItem> items = new ArrayList<>();
    for (Object source : sources) {
      items.add(mediaItem((Map<?, ?>) source));
    }
    Number position = call.argument("initialPosition");
    player.setMediaItems(
        items, intArg(call, "initialIndex"), position != null ? position.longValue() : 0);
    player.prepare();
    pendingLoad = result;
  }

  private void seek(MethodCall call, MethodChannel.Result result) {
    completeSeek();
    Number position = call.argument("position");
    long positionMs = position != null ? position.longValue() : 0;
    Number index = call.argument("index");
    if (index != null) {
      player.seekTo(index.intValue(), positionMs);
    } else {
      player.seekTo(positionMs);
    }
    // A seek turns a ready or ended player into buffering until the target is ready
    if (player.getPlaybackState() == Player.STATE_BUFFERING) {
      pendingSeek = result;
    } else {
      result.success(snapshot());
    }
  }

  /** A load replaced by another one, or by stop(). */
  private void interruptLoad() {
    if (pendingLoad != null) {
      pendingLoad.error("interrupted", "Loading interrupted", null);
      pendingLoad = null;
    }
  }

  private void completeSeek() {
    if (pendingSeek != null) {
      pendingSeek.success(snapshot());
      pendingSeek = null;
    }
  }

  @Override
  public void onPlayerError(@NonNull PlaybackException error) {
    Map<String, Object> event = new HashMap<>();
    event.put("type", "error");
    event.put("code", error.errorCode);
    event.put("message", error.getMessage());
    event.put("index", errorIndex(error));
    send(event);
    if (pendingLoad != null) {
      pendingLoad.error("error", error.getMessage(), event);
      pendingLoad = null;
    }
  }

  /** The playlist index of the item that failed. */
  @Nullable
  private Integer errorIndex(PlaybackException error) {
    if (error instanceof ExoPlaybackException) {
      ExoPlaybackException exoError = (ExoPlaybackException) error;
      Timeline timeline = player.getCurrentTimeline();
      if (exoError.mediaPeriodId != null && !timeline.isEmpty()) {
        int periodIndex = timeline.getIndexOfPeriod(exoError.mediaPeriodId.periodUid);
        if (periodIndex != C.INDEX_UNSET) {
          return timeline.getPeriod(periodIndex, new Timeline.Period()).windowIndex;
        }
      }
    }
    return currentIndex();
  }

  @Override
  public void onEvents(@NonNull Player player, @NonNull Player.Events events) {
    int state = player.getPlaybackState();
    if (pendingLoad != null && (state == Player.STATE_READY || state == Player.STATE_ENDED)) {
      pendingLoad.success(snapshot());
      pendingLoad = null;
    }
    if (pendingSeek != null && state != Player.STATE_BUFFERING) {
      completeSeek();
    }
    sendState();
    handler.removeCallbacks(positionUpdate);
    if (player.isPlaying()) {
      handler.postDelayed(positionUpdate, POSITION_UPDATE_INTERVAL_MS);
    }
  }

  private void onPositionUpdate() {
    sendState();
    if (player.isPlaying()) {
      handler.postDelayed(positionUpdate, POSITION_UPDATE_INTERVAL_MS);
    }
  }

  @Nullable
  private Integer currentIndex() {
    return player.getMediaItemCount() == 0 ? null : player.getCurrentMediaItemIndex();
  }

  private Map<String, Object> snapshot() {
    Map<String, Object> state = new HashMap<>();
    state.put("type", "state");
    switch (player.getPlaybackState()) {
      case Player.STATE_BUFFERING:
        state.put("processingState", STATE_BUFFERING);
        break;
      case Player.STATE_READY:
        state.put("processingState", STATE_READY);
        break;
      case Player.STATE_ENDED:
        state.put("processingState", STATE_COMPLETED);
        break;
      default:
        state.put("processingState", STATE_IDLE);
    }
    // Playing as the user sees it: while audio focus is lost for a moment, playback is paused
    state.put(
        "playing",
        player.getPlayWhenReady()
            && player.getPlaybackSuppressionReason() == Player.PLAYBACK_SUPPRESSION_REASON_NONE);
    state.put("index", currentIndex());
    state.put("position", player.getCurrentPosition());
    long duration = player.getDuration();
    state.put("duration", duration == C.TIME_UNSET ? null : duration);
    return state;
  }

  private void sendState() {
    send(snapshot());
  }

  private void send(Map<String, Object> event) {
    if (eventSink != null) eventSink.success(event);
  }

  void release() {
    handler.removeCallbacks(positionUpdate);
    interruptLoad();
    completeSeek();
    methodChannel.setMethodCallHandler(null);
    eventChannel.setStreamHandler(null);
    eventSink = null;
    player.removeListener(this);
    player.release();
  }
}
