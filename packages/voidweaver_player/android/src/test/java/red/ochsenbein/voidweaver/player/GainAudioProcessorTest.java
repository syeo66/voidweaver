package red.ochsenbein.voidweaver.player;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import androidx.media3.common.C;
import androidx.media3.common.Timeline;
import androidx.media3.common.audio.AudioProcessor.AudioFormat;
import androidx.media3.common.audio.AudioProcessor.StreamMetadata;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
public final class GainAudioProcessorTest {
  private static final AudioFormat PCM_16 = new AudioFormat(44100, 2, C.ENCODING_PCM_16BIT);
  private static final AudioFormat PCM_FLOAT = new AudioFormat(44100, 2, C.ENCODING_PCM_FLOAT);

  // Items "a", "b", "c"
  private final Timeline timeline = new FakePlayer(3).getCurrentTimeline();
  private GainAudioProcessor processor;

  @Before
  public void setUp() throws Exception {
    processor = new GainAudioProcessor();
    processor.configure(PCM_16);
  }

  /** Flushes the processor as the sink does at the start of the item at [index]. */
  private void startItem(int index) {
    processor.flush(
        new StreamMetadata.Builder()
            .setTimeline(timeline)
            .setPeriodUid(timeline.getUidOfPeriod(index))
            .build());
  }

  private short[] process(short... samples) {
    ByteBuffer input =
        ByteBuffer.allocateDirect(samples.length * 2).order(ByteOrder.nativeOrder());
    for (short sample : samples) input.putShort(sample);
    input.flip();
    processor.queueInput(input);
    ByteBuffer output = processor.getOutput();
    short[] result = new short[output.remaining() / 2];
    output.asShortBuffer().get(result);
    return result;
  }

  @Test
  public void appliesTheGainOfTheCurrentItem() {
    processor.setGain("b", 0.5f);
    startItem(1);

    assertArrayEquals(new short[] {500, -500, 15000}, process((short) 1000, (short) -1000, (short) 30000));
  }

  @Test
  public void switchesGainWhereTheNextItemStarts() {
    processor.setGain("a", 0.5f);
    processor.setGain("b", 2f);
    startItem(0);
    assertArrayEquals(new short[] {500}, process((short) 1000));

    startItem(1);
    assertArrayEquals(new short[] {2000}, process((short) 1000));
  }

  @Test
  public void clipsAtFullScale() {
    processor.setGain("a", 2f);
    startItem(0);

    assertArrayEquals(
        new short[] {Short.MAX_VALUE, Short.MIN_VALUE}, process((short) 20000, (short) -20000));
  }

  @Test
  public void playsAnItemWithoutGainUnchanged() {
    processor.setGain("a", 0.5f);
    startItem(2);

    assertArrayEquals(new short[] {1000, -7}, process((short) 1000, (short) -7));
  }

  @Test
  public void appliesAGainChangedWhilePlaying() {
    startItem(0);
    assertArrayEquals(new short[] {1000}, process((short) 1000));

    processor.setGain("a", 0.25f);
    assertArrayEquals(new short[] {250}, process((short) 1000));
  }

  @Test
  public void keepsTheItemOnAFlushWithoutOne() {
    processor.setGain("a", 0.5f);
    startItem(0);

    processor.flush(StreamMetadata.DEFAULT);

    assertArrayEquals(new short[] {500}, process((short) 1000));
  }

  @Test
  public void forgetsTheItemOnReset() throws Exception {
    processor.setGain("a", 0.5f);
    startItem(0);

    processor.reset();
    processor.configure(PCM_16);
    processor.flush(StreamMetadata.DEFAULT);

    assertArrayEquals(new short[] {1000}, process((short) 1000));
  }

  @Test
  public void appliesTheGainToFloatSamples() throws Exception {
    processor.configure(PCM_FLOAT);
    processor.setGain("a", 0.5f);
    startItem(0);

    ByteBuffer input = ByteBuffer.allocateDirect(8).order(ByteOrder.nativeOrder());
    input.putFloat(0.8f).putFloat(-1.5f).flip();
    processor.queueInput(input);
    ByteBuffer output = processor.getOutput();

    assertEquals(0.4f, output.getFloat(), 1e-6f);
    assertEquals(-0.75f, output.getFloat(), 1e-6f);
  }

  @Test
  public void isInactiveForOtherEncodings() throws Exception {
    assertTrue(processor.isActive());

    processor.configure(new AudioFormat(44100, 2, C.ENCODING_PCM_24BIT));
    processor.flush(StreamMetadata.DEFAULT);

    assertFalse(processor.isActive());
  }
}
