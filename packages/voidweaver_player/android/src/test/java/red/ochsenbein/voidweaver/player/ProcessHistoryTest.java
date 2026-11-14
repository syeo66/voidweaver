package red.ochsenbein.voidweaver.player;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.Context;
import java.io.File;
import java.net.UnknownHostException;
import java.util.Arrays;
import java.util.List;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;

@RunWith(RobolectricTestRunner.class)
public final class ProcessHistoryTest {
  private static final int FOREGROUND_SERVICE =
      ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE;
  private static final int CACHED = ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED;
  // 2026-11-14 10:01:02 UTC
  private static final long TIME = 1794650462000L;

  private Context context;
  private File crashFile;

  @Before
  public void setUp() {
    context = RuntimeEnvironment.getApplication();
    crashFile = new File(context.getFilesDir(), "voidweaver_crash.txt");
    crashFile.delete();
  }

  private static ProcessHistory.Exit exit(int reason, int importance) {
    return new ProcessHistory.Exit(reason, importance, TIME, null, 0);
  }

  @Test
  public void noCrashFileMeansNoCrashEntry() {
    for (ProcessHistory.Entry entry : ProcessHistory.takeNew(context)) {
      assertFalse(entry.text, entry.text.contains("crashed"));
    }
  }

  @Test
  public void aRecordedCrashIsReportedOnceWithItsStack() throws Exception {
    RuntimeException error = new IllegalStateException("player exploded");

    ProcessHistory.record(crashFile, Thread.currentThread(), error, TIME);
    List<ProcessHistory.Entry> first = ProcessHistory.takeNew(context);
    List<ProcessHistory.Entry> second = ProcessHistory.takeNew(context);

    ProcessHistory.Entry crash = first.get(0);
    assertTrue(crash.notable);
    assertTrue(crash.text, crash.text.startsWith("The previous run crashed. "));
    assertTrue(crash.text, crash.text.contains("IllegalStateException: player exploded"));
    assertTrue(crash.text, crash.text.contains("aRecordedCrashIsReportedOnceWithItsStack"));
    assertTrue(crash.text, crash.text.contains("2026-11-14 10:01:02 UTC"));
    // Reported once
    assertFalse(crashFile.exists());
    for (ProcessHistory.Entry entry : second) {
      assertFalse(entry.text, entry.text.contains("crashed"));
    }
  }

  @Test
  public void aCrashCausedByAFailedDnsLookupKeepsItsStack() throws Exception {
    // android.util.Log.getStackTraceString() returns "" for these
    RuntimeException error = new RuntimeException("x", new UnknownHostException("music.example.com"));

    ProcessHistory.record(crashFile, Thread.currentThread(), error, TIME);

    ProcessHistory.Entry crash = ProcessHistory.takeNew(context).get(0);
    assertTrue(crash.text, crash.text.contains("RuntimeException: x"));
    assertTrue(crash.text, crash.text.contains("UnknownHostException: music.example.com"));
    assertTrue(crash.text, crash.text.contains("aCrashCausedByAFailedDnsLookupKeepsItsStack"));
  }

  @Test
  public void onlyTheLastCrashIsKept() throws Exception {
    ProcessHistory.record(crashFile, Thread.currentThread(), new RuntimeException("first"), TIME);
    ProcessHistory.record(crashFile, Thread.currentThread(), new RuntimeException("second"), TIME);

    ProcessHistory.Entry crash = ProcessHistory.takeNew(context).get(0);

    assertTrue(crash.text, crash.text.contains("second"));
    assertFalse(crash.text, crash.text.contains("first"));
  }

  @Test
  public void aHugeStackIsCut() throws Exception {
    StringBuilder message = new StringBuilder();
    for (int i = 0; i < 20000; i++) message.append('x');

    ProcessHistory.record(
        crashFile, Thread.currentThread(), new RuntimeException(message.toString()), TIME);

    ProcessHistory.Entry crash = ProcessHistory.takeNew(context).get(0);
    assertTrue(crash.text.length() < 9000);
    assertTrue(crash.text.endsWith("(cut)"));
  }

  @Test
  public void describesAnExitWithItsReasonStateAndMemory() {
    ProcessHistory.Exit exit =
        new ProcessHistory.Exit(
            ApplicationExitInfo.REASON_LOW_MEMORY,
            FOREGROUND_SERVICE,
            TIME,
            "kill pid 123 (oom)",
            // 180 MB
            180 * 1024);

    assertEquals(
        "A process of the app ended at 2026-11-14 10:01:02 UTC: killed for low memory, running a"
            + " foreground service, 180 MB in memory (kill pid 123 (oom))",
        ProcessHistory.describe(exit));
  }

  @Test
  public void leavesOutWhatIsUnknown() {
    assertEquals(
        "A process of the app ended at 2026-11-14 10:01:02 UTC: stopped by the user, cached",
        ProcessHistory.describe(exit(ApplicationExitInfo.REASON_USER_REQUESTED, CACHED)));
  }

  @Test
  public void crashesAndNotRespondingAreNotable() {
    assertTrue(ProcessHistory.isNotable(exit(ApplicationExitInfo.REASON_CRASH, CACHED)));
    assertTrue(ProcessHistory.isNotable(exit(ApplicationExitInfo.REASON_CRASH_NATIVE, CACHED)));
    assertTrue(ProcessHistory.isNotable(exit(ApplicationExitInfo.REASON_ANR, CACHED)));
  }

  @Test
  public void aKillIsNotableUnlessTheProcessWasCached() {
    // Android clears cached processes all the time
    assertFalse(ProcessHistory.isNotable(exit(ApplicationExitInfo.REASON_LOW_MEMORY, CACHED)));
    // But not one that was playing
    assertTrue(
        ProcessHistory.isNotable(exit(ApplicationExitInfo.REASON_LOW_MEMORY, FOREGROUND_SERVICE)));
    assertTrue(
        ProcessHistory.isNotable(exit(ApplicationExitInfo.REASON_SIGNALED, FOREGROUND_SERVICE)));
  }

  @Test
  public void aUsersStopIsNotNotable() {
    assertFalse(
        ProcessHistory.isNotable(
            exit(ApplicationExitInfo.REASON_USER_REQUESTED, FOREGROUND_SERVICE)));
    assertFalse(
        ProcessHistory.isNotable(exit(ApplicationExitInfo.REASON_EXIT_SELF, FOREGROUND_SERVICE)));
  }

  @Test
  public void reportsOnlyExitsAfterTheLastReportOldestFirst() {
    ProcessHistory.Exit newest =
        new ProcessHistory.Exit(ApplicationExitInfo.REASON_ANR, CACHED, TIME + 2000, null, 0);
    ProcessHistory.Exit middle =
        new ProcessHistory.Exit(ApplicationExitInfo.REASON_CRASH, CACHED, TIME + 1000, null, 0);
    ProcessHistory.Exit old =
        new ProcessHistory.Exit(ApplicationExitInfo.REASON_CRASH, CACHED, TIME, null, 0);

    // Android lists the newest first
    List<ProcessHistory.Entry> entries =
        ProcessHistory.describeNew(Arrays.asList(newest, middle, old), TIME);

    assertEquals(2, entries.size());
    assertTrue(entries.get(0).text, entries.get(0).text.contains("crash (uncaught exception)"));
    assertTrue(entries.get(1).text, entries.get(1).text.contains("not responding"));
  }

  @Test
  public void nothingNewMeansNoEntries() {
    assertTrue(
        ProcessHistory.describeNew(
                Arrays.asList(exit(ApplicationExitInfo.REASON_CRASH, CACHED)), TIME)
            .isEmpty());
  }
}
