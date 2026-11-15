package red.ochsenbein.voidweaver.player;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import androidx.media3.common.AdPlaybackState;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.Timeline;
import androidx.media3.exoplayer.LoadControl;
import androidx.media3.exoplayer.analytics.PlayerId;
import androidx.media3.exoplayer.source.MediaSource;
import androidx.media3.exoplayer.upstream.Allocator;
import androidx.media3.exoplayer.upstream.DefaultAllocator;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
public final class TrackBufferLoadControlTest {
  private static final long NEXT_LIMIT_US = TrackBufferLoadControl.NEXT_ITEM_BUFFER_MS * 1000;

  private final RecordingLoadControl delegate = new RecordingLoadControl();
  private final TrackBufferLoadControl control = new TrackBufferLoadControl(delegate);
  private final Timeline timeline = new Playlist(3);

  @Test
  public void thePlayingItemBuffersAsFarAsTheDelegateAllows() {
    control.setPlayingIndex(1);

    assertTrue(control.shouldContinueLoading(loading(1, 5 * 60 * 1_000_000L)));
    assertEquals(1, delegate.calls);
  }

  @Test
  public void aLaterItemStopsAtTheDefaultBuffer() {
    control.setPlayingIndex(0);

    assertTrue(control.shouldContinueLoading(loading(1, NEXT_LIMIT_US - 1)));
    assertFalse(control.shouldContinueLoading(loading(1, NEXT_LIMIT_US)));
    // Only the call below the limit reached the delegate
    assertEquals(1, delegate.calls);
  }

  @Test
  public void belowTheDefaultBufferTheDelegateStillDecides() {
    control.setPlayingIndex(0);
    delegate.answer = false;

    assertFalse(control.shouldContinueLoading(loading(2, 1_000_000L)));
  }

  @Test
  public void aStaleIndexOnlyLimitsTheNewTrackToTheDefault() {
    // The player moved on to 1, the main thread hasn't seen it yet
    control.setPlayingIndex(0);

    assertFalse(control.shouldContinueLoading(loading(1, NEXT_LIMIT_US)));
    control.setPlayingIndex(1);
    assertTrue(control.shouldContinueLoading(loading(1, NEXT_LIMIT_US)));
  }

  @Test
  public void anEmptyTimelineIsLeftToTheDelegate() {
    control.setPlayingIndex(C.INDEX_UNSET);
    LoadControl.Parameters parameters =
        parameters(Timeline.EMPTY, new MediaSource.MediaPeriodId(new Object()), NEXT_LIMIT_US);

    assertTrue(control.shouldContinueLoading(parameters));
  }

  @Test
  public void theAllocatorIsTheDelegates() {
    assertEquals(delegate.allocator, control.getAllocator(PlayerId.UNSET));
  }

  private LoadControl.Parameters loading(int index, long bufferedUs) {
    return parameters(timeline, new MediaSource.MediaPeriodId(index), bufferedUs);
  }

  private static LoadControl.Parameters parameters(
      Timeline timeline, MediaSource.MediaPeriodId id, long bufferedUs) {
    return new LoadControl.Parameters(
        PlayerId.UNSET,
        timeline,
        id,
        /* playbackPositionUs= */ 0,
        bufferedUs,
        /* playbackSpeed= */ 1f,
        /* playWhenReady= */ true,
        /* rebuffering= */ false,
        /* targetLiveOffsetUs= */ C.TIME_UNSET,
        /* lastRebufferRealtimeMs= */ C.TIME_UNSET);
  }

  /** One window per item with one period each, its uid the index, like the player's playlist. */
  private static final class Playlist extends Timeline {
    private final int count;

    Playlist(int count) {
      this.count = count;
    }

    @Override
    public int getWindowCount() {
      return count;
    }

    @Override
    public Window getWindow(int windowIndex, Window window, long defaultPositionProjectionUs) {
      return window.set(
          windowIndex,
          MediaItem.EMPTY,
          null,
          C.TIME_UNSET,
          C.TIME_UNSET,
          C.TIME_UNSET,
          true,
          false,
          null,
          0,
          C.TIME_UNSET,
          windowIndex,
          windowIndex,
          0);
    }

    @Override
    public int getPeriodCount() {
      return count;
    }

    @Override
    public Period getPeriod(int periodIndex, Period period, boolean setIds) {
      return period.set(
          periodIndex,
          periodIndex,
          periodIndex,
          C.TIME_UNSET,
          0,
          AdPlaybackState.NONE,
          /* isPlaceholder= */ false);
    }

    @Override
    public int getIndexOfPeriod(Object uid) {
      return uid instanceof Integer && (Integer) uid < count ? (Integer) uid : C.INDEX_UNSET;
    }

    @Override
    public Object getUidOfPeriod(int periodIndex) {
      return periodIndex;
    }
  }

  private static final class RecordingLoadControl implements LoadControl {
    final Allocator allocator = new DefaultAllocator(true, 1024);
    boolean answer = true;
    int calls;

    @Override
    public Allocator getAllocator(PlayerId playerId) {
      return allocator;
    }

    @Override
    public boolean shouldContinueLoading(Parameters parameters) {
      calls++;
      return answer;
    }
  }
}
