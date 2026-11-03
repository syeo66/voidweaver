/// Formatting of durations and sizes for display and logs.
library;

/// A playback time or track length as `m:ss`, e.g. `3:05` or `75:00`.
String formatClock(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// A longer span (an album, a sleep timer) in hours and minutes, e.g.
/// `1h 5m` or `45m`.
String formatHoursMinutes(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes % 60;
  return hours > 0 ? '${hours}h ${minutes}m' : '${minutes}m';
}

/// A size in bytes, e.g. `512 B`, `12 KB`, `3.4 MB`, `1.25 GB`.
String formatBytes(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes < kb) return '$bytes B';
  if (bytes < mb) return '${(bytes / kb).toStringAsFixed(0)} KB';
  if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / gb).toStringAsFixed(2)} GB';
}
