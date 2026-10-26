package red.ochsenbein.voidweaver.player;

import android.util.Log;
import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.common.Timeline;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Applies a gain per playlist item to the decoded samples, before they reach the audio output.
 *
 * <p>The audio sink drains its processors and flushes them with the new item's {@link
 * StreamMetadata} exactly where one item's samples end and the next one's begin, also during a
 * gapless transition. So each item plays at its own gain from its first sample to its last, unlike
 * the player's volume, which applies to whatever is playing when it changes.
 *
 * <p>Gains are keyed by the media ID of the item. They can be changed at any time (from the main
 * thread); the change applies from the next buffer on.
 */
final class GainAudioProcessor extends BaseAudioProcessor {
  private static final String TAG = "VoidweaverGain";

  private final Map<String, Float> gains = new ConcurrentHashMap<>();
  private final Timeline.Period period = new Timeline.Period();
  private final Timeline.Window window = new Timeline.Window();

  // The item whose samples are being processed. Only used on the playback thread.
  @Nullable private String itemId;

  void setGain(String itemId, float gain) {
    gains.put(itemId, gain);
  }

  void clearGains() {
    gains.clear();
  }

  @Override
  protected AudioFormat onConfigure(AudioFormat inputAudioFormat) {
    // The sink converts to 16-bit PCM before its custom processors. Anything else (float output
    // isn't enabled) would play without gain rather than not at all.
    return inputAudioFormat.encoding == C.ENCODING_PCM_16BIT
            || inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT
        ? inputAudioFormat
        : AudioFormat.NOT_SET;
  }

  @Override
  protected void onFlush(StreamMetadata streamMetadata) {
    // Flushes without an item (e.g. a reset) keep the current one
    if (streamMetadata.timeline.isEmpty() || streamMetadata.periodUid == null) return;
    int windowIndex =
        streamMetadata.timeline.getPeriodByUid(streamMetadata.periodUid, period).windowIndex;
    String id = streamMetadata.timeline.getWindow(windowIndex, window).mediaItem.mediaId;
    if (!id.equals(itemId)) {
      itemId = id;
      Log.d(TAG, "Item " + id + " (index " + windowIndex + "), gain " + currentGain());
    }
  }

  @Override
  protected void onReset() {
    itemId = null;
  }

  private float currentGain() {
    @Nullable Float gain = itemId != null ? gains.get(itemId) : null;
    return gain != null ? gain : 1f;
  }

  @Override
  public void queueInput(ByteBuffer inputBuffer) {
    int position = inputBuffer.position();
    int limit = inputBuffer.limit();
    if (position == limit) return;
    float gain = currentGain();
    ByteBuffer buffer = replaceOutputBuffer(limit - position);
    if (gain == 1f) {
      buffer.put(inputBuffer);
    } else if (inputAudioFormat.encoding == C.ENCODING_PCM_16BIT) {
      for (int i = position; i < limit; i += 2) {
        int sample = Math.round(inputBuffer.getShort(i) * gain);
        buffer.putShort((short) Math.max(Short.MIN_VALUE, Math.min(Short.MAX_VALUE, sample)));
      }
    } else {
      for (int i = position; i < limit; i += 4) {
        buffer.putFloat(inputBuffer.getFloat(i) * gain);
      }
    }
    inputBuffer.position(limit);
    buffer.flip();
  }
}
