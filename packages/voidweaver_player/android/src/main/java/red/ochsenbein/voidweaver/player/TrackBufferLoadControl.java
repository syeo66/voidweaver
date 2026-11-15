package red.ochsenbein.voidweaver.player;

import androidx.media3.common.C;
import androidx.media3.common.Timeline;
import androidx.media3.exoplayer.DefaultLoadControl;
import androidx.media3.exoplayer.LoadControl;
import androidx.media3.exoplayer.analytics.PlayerId;
import androidx.media3.exoplayer.source.MediaSource;
import androidx.media3.exoplayer.source.TrackGroupArray;
import androidx.media3.exoplayer.trackselection.ExoTrackSelection;
import androidx.media3.exoplayer.upstream.Allocator;

/**
 * Buffers the track that's playing far ahead ({@link #MAX_BUFFER_MS}, up to {@link
 * #TARGET_BUFFER_BYTES}), so a track that streams (not downloaded yet, typically the first one of a
 * new queue) survives a longer network drop. The default maximum of {@link DefaultLoadControl}
 * is 50 s.
 *
 * <p>Later tracks are only buffered as far as Media3 would by default ({@link #NEXT_ITEM_BUFFER_MS}
 * in all): the downloads ahead fetch them into the cache, and the player loading one at the same
 * time would download it a second time, as the cache lets only one of them write it.
 *
 * <p>The playing item comes from the main thread ({@link #setPlayingIndex}), while ExoPlayer asks
 * on its playback thread. Right after a track change the index can be behind, which only makes the
 * new track buffer like a later one until it's updated.
 */
final class TrackBufferLoadControl implements LoadControl {
  static final int MAX_BUFFER_MS = 10 * 60 * 1000;
  // Enough for a whole song at 320 kbps; for lossless files, this limits before the time does
  static final int TARGET_BUFFER_BYTES = 32 * 1024 * 1024;
  static final long NEXT_ITEM_BUFFER_MS = DefaultLoadControl.DEFAULT_MAX_BUFFER_MS;

  private final LoadControl delegate;
  private final Timeline.Period period = new Timeline.Period();
  private volatile int playingIndex = C.INDEX_UNSET;

  TrackBufferLoadControl() {
    this(
        new DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                DefaultLoadControl.DEFAULT_MIN_BUFFER_MS,
                MAX_BUFFER_MS,
                DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_MS,
                DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS)
            .setTargetBufferBytes(TARGET_BUFFER_BYTES)
            .build());
  }

  TrackBufferLoadControl(LoadControl delegate) {
    this.delegate = delegate;
  }

  /** The playlist index of the item that's playing. Call on the main thread when it changes. */
  void setPlayingIndex(int index) {
    playingIndex = index;
  }

  @Override
  public boolean shouldContinueLoading(Parameters parameters) {
    if (!loadsPlayingItem(parameters)
        && parameters.bufferedDurationUs >= NEXT_ITEM_BUFFER_MS * 1000) {
      return false;
    }
    return delegate.shouldContinueLoading(parameters);
  }

  // Called on the playback thread only, which owns [period]
  private boolean loadsPlayingItem(Parameters parameters) {
    Timeline timeline = parameters.timeline;
    if (timeline.isEmpty()) return true;
    int periodIndex = timeline.getIndexOfPeriod(parameters.mediaPeriodId.periodUid);
    if (periodIndex == C.INDEX_UNSET) return true;
    return timeline.getPeriod(periodIndex, period).windowIndex == playingIndex;
  }

  @Override
  public void onPrepared(PlayerId playerId) {
    delegate.onPrepared(playerId);
  }

  @Override
  public void onTracksSelected(
      Parameters parameters, TrackGroupArray trackGroups, ExoTrackSelection[] trackSelections) {
    delegate.onTracksSelected(parameters, trackGroups, trackSelections);
  }

  @Override
  public void onStopped(PlayerId playerId) {
    delegate.onStopped(playerId);
  }

  @Override
  public void onReleased(PlayerId playerId) {
    delegate.onReleased(playerId);
  }

  @Override
  public Allocator getAllocator(PlayerId playerId) {
    return delegate.getAllocator(playerId);
  }

  @Override
  public long getBackBufferDurationUs(PlayerId playerId) {
    return delegate.getBackBufferDurationUs(playerId);
  }

  @Override
  public boolean retainBackBufferFromKeyframe(PlayerId playerId) {
    return delegate.retainBackBufferFromKeyframe(playerId);
  }

  @Override
  public boolean shouldStartPlayback(Parameters parameters) {
    return delegate.shouldStartPlayback(parameters);
  }

  // Not capped for later items like shouldContinueLoading: the player has no preload sources. Add
  // the cap here if preloading is ever used.
  @Override
  public boolean shouldContinuePreloading(
      PlayerId playerId,
      Timeline timeline,
      MediaSource.MediaPeriodId mediaPeriodId,
      long bufferedDurationUs) {
    return delegate.shouldContinuePreloading(
        playerId, timeline, mediaPeriodId, bufferedDurationUs);
  }
}
