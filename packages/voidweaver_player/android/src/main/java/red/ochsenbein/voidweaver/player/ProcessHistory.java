package red.ochsenbein.voidweaver.player;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import android.util.Log;
import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;
import java.io.File;
import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;

/**
 * How earlier runs of the app ended, for the app's session log: nothing leaves the device. Android
 * kills a background player for memory, an ANR or a crash without the app seeing it, so the log of
 * that run just stops. Two sources are reported on the next start:
 *
 * <ul>
 *   <li>The stack of an uncaught Java exception, saved by {@link #installCrashRecorder} before the
 *       process dies.
 *   <li>Android's own record of why a process ended ({@link ApplicationExitInfo}, Android 11 and
 *       newer): a kill for low memory, an ANR, a native crash, a user's force stop.
 * </ul>
 */
final class ProcessHistory {
  private static final String TAG = "VoidweaverPlayer";
  private static final String PREFS = "voidweaver_player.exits";
  private static final String LAST_REPORTED = "lastReported";
  private static final String CRASH_FILE = "voidweaver_crash.txt";
  /** The most exits reported at once, the newest first; older ones aren't interesting any more. */
  private static final int MAX_EXITS = 5;
  /** Enough for a deep stack; a crash file is read into the log, which has a size limit. */
  private static final int MAX_CRASH_CHARS = 8000;

  private static boolean installed;

  private ProcessHistory() {}

  /** One line for the log. [notable] ones are things that went wrong. */
  static final class Entry {
    final String text;
    final boolean notable;

    Entry(String text, boolean notable) {
      this.text = text;
      this.notable = notable;
    }
  }

  /** What [ApplicationExitInfo] holds, as plain data, so the wording can be tested. */
  static final class Exit {
    final int reason;
    final int importance;
    final long timestamp;
    @Nullable final String description;
    final long rssKb;

    Exit(int reason, int importance, long timestamp, @Nullable String description, long rssKb) {
      this.reason = reason;
      this.importance = importance;
      this.timestamp = timestamp;
      this.description = description;
      this.rssKb = rssKb;
    }
  }

  // Java crash recorder

  /**
   * Saves the stack of an uncaught exception to a file before the process dies, then lets the
   * previous handler (Android's, which shows the crash dialog and ends the process) go on. Once per
   * process, however often the plugin is attached.
   */
  static synchronized void installCrashRecorder(Context context) {
    if (installed) return;
    installed = true;
    File file = crashFile(context);
    Thread.UncaughtExceptionHandler previous = Thread.getDefaultUncaughtExceptionHandler();
    Thread.setDefaultUncaughtExceptionHandler(
        (thread, error) -> {
          try {
            record(file, thread, error, System.currentTimeMillis());
          } catch (Throwable ignored) {
            // The crash goes on to the previous handler whatever happens here
          }
          if (previous != null) previous.uncaughtException(thread, error);
        });
  }

  static void record(File file, Thread thread, Throwable error, long now) throws IOException {
    // Not Log.getStackTraceString(), which returns "" when the chain has an UnknownHostException
    StringWriter writer = new StringWriter();
    error.printStackTrace(new PrintWriter(writer));
    String stack = writer.toString();
    if (stack.length() > MAX_CRASH_CHARS) {
      stack = stack.substring(0, MAX_CRASH_CHARS) + "\n... (cut)";
    }
    String text = "Uncaught exception on thread \"" + thread.getName() + "\" at " + time(now) + "\n" + stack;
    // Not appended: only the last crash before the next start matters
    try (FileOutputStream out = new FileOutputStream(file, false)) {
      out.write(text.getBytes(StandardCharsets.UTF_8));
      // The process is about to end
      out.getFD().sync();
    }
  }

  private static File crashFile(Context context) {
    return new File(context.getApplicationContext().getFilesDir(), CRASH_FILE);
  }

  // Reporting

  /**
   * What happened to the runs before this one that wasn't reported yet: a saved crash, then the
   * exits Android recorded since the last report, oldest first (the crash may be newer than some of
   * them). Reported once; the next call
   * returns nothing new.
   */
  static List<Entry> takeNew(Context context) {
    List<Entry> entries = new ArrayList<>();
    File file = crashFile(context);
    if (file.exists()) {
      try {
        String text = read(file);
        entries.add(new Entry("The previous run crashed. " + text, true));
      } catch (IOException e) {
        Log.w(TAG, "Could not read the saved crash", e);
      }
      // Also if it couldn't be read: it would only fail again
      if (!file.delete()) Log.w(TAG, "Could not delete the saved crash");
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      try {
        entries.addAll(newExits(context));
      } catch (RuntimeException e) {
        Log.w(TAG, "Could not read the process exit reasons", e);
      }
    }
    return entries;
  }

  private static String read(File file) throws IOException {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    try (FileInputStream in = new FileInputStream(file)) {
      byte[] buffer = new byte[4096];
      int count;
      while ((count = in.read(buffer)) != -1) bytes.write(buffer, 0, count);
    }
    return new String(bytes.toByteArray(), StandardCharsets.UTF_8);
  }

  @RequiresApi(Build.VERSION_CODES.R)
  private static List<Entry> newExits(Context context) {
    Context app = context.getApplicationContext();
    ActivityManager manager = (ActivityManager) app.getSystemService(Context.ACTIVITY_SERVICE);
    SharedPreferences prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    long lastReported = prefs.getLong(LAST_REPORTED, 0);
    List<ApplicationExitInfo> infos = manager.getHistoricalProcessExitReasons(null, 0, MAX_EXITS);
    List<Exit> exits = new ArrayList<>();
    long newest = lastReported;
    for (ApplicationExitInfo info : infos) {
      newest = Math.max(newest, info.getTimestamp());
      exits.add(
          new Exit(
              info.getReason(),
              info.getImportance(),
              info.getTimestamp(),
              info.getDescription(),
              info.getRss()));
    }
    if (newest != lastReported) prefs.edit().putLong(LAST_REPORTED, newest).apply();
    return describeNew(exits, lastReported);
  }

  /** The entries for the [exits] after [lastReported], oldest first. */
  static List<Entry> describeNew(List<Exit> exits, long lastReported) {
    List<Entry> entries = new ArrayList<>();
    for (int i = exits.size() - 1; i >= 0; i--) {
      Exit exit = exits.get(i);
      if (exit.timestamp > lastReported) {
        entries.add(new Entry(describe(exit), isNotable(exit)));
      }
    }
    return entries;
  }

  static String describe(Exit exit) {
    StringBuilder text =
        new StringBuilder("A process of the app ended at ")
            .append(time(exit.timestamp))
            .append(": ")
            .append(reasonName(exit.reason))
            .append(", ")
            .append(importanceName(exit.importance));
    if (exit.rssKb > 0) text.append(", ").append(exit.rssKb / 1024).append(" MB in memory");
    if (exit.description != null && !exit.description.isEmpty()) {
      text.append(" (").append(exit.description).append(")");
    }
    return text.toString();
  }

  /**
   * Whether the exit means something went wrong. A user's stop and the system's cleanup of a
   * cached process, which Android does all the time, don't.
   */
  static boolean isNotable(Exit exit) {
    switch (exit.reason) {
      case ApplicationExitInfo.REASON_ANR:
      case ApplicationExitInfo.REASON_CRASH:
      case ApplicationExitInfo.REASON_CRASH_NATIVE:
      case ApplicationExitInfo.REASON_INITIALIZATION_FAILURE:
      case ApplicationExitInfo.REASON_DEPENDENCY_DIED:
      case ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE:
        return true;
      case ApplicationExitInfo.REASON_LOW_MEMORY:
      case ApplicationExitInfo.REASON_SIGNALED:
      case ApplicationExitInfo.REASON_OTHER:
      case ApplicationExitInfo.REASON_UNKNOWN:
        // Killed for memory or by a signal while it mattered, not while cached
        return exit.importance < ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED;
      default:
        return false;
    }
  }

  // The constants are inlined by the compiler, so newer ones are safe on older systems
  static String reasonName(int reason) {
    switch (reason) {
      case ApplicationExitInfo.REASON_ANR:
        return "not responding (ANR)";
      case ApplicationExitInfo.REASON_CRASH:
        return "crash (uncaught exception)";
      case ApplicationExitInfo.REASON_CRASH_NATIVE:
        return "native crash";
      case ApplicationExitInfo.REASON_DEPENDENCY_DIED:
        return "a process it depends on died";
      case ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE:
        return "killed for using too many resources";
      case ApplicationExitInfo.REASON_EXIT_SELF:
        return "the app exited itself";
      case ApplicationExitInfo.REASON_FREEZER:
        return "frozen and killed by the system";
      case ApplicationExitInfo.REASON_INITIALIZATION_FAILURE:
        return "failed to start";
      case ApplicationExitInfo.REASON_LOW_MEMORY:
        return "killed for low memory";
      case ApplicationExitInfo.REASON_PERMISSION_CHANGE:
        return "a permission changed";
      case ApplicationExitInfo.REASON_SIGNALED:
        return "killed by a signal";
      case ApplicationExitInfo.REASON_USER_REQUESTED:
        return "stopped by the user";
      case ApplicationExitInfo.REASON_USER_STOPPED:
        return "stopped with its user";
      case ApplicationExitInfo.REASON_OTHER:
        return "ended for another reason";
      default:
        return "ended for an unknown reason (" + reason + ")";
    }
  }

  static String importanceName(int importance) {
    if (importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND) {
      return "in the foreground";
    }
    if (importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE) {
      return "running a foreground service";
    }
    if (importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE) {
      return "visible";
    }
    if (importance < ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED) {
      return "in the background";
    }
    return "cached";
  }

  private static String time(long millis) {
    SimpleDateFormat format = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss 'UTC'", Locale.US);
    format.setTimeZone(TimeZone.getTimeZone("UTC"));
    return format.format(new Date(millis));
  }
}
