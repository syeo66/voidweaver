import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/log.dart';

final _log = Logger('session_log');

/// The log of this run of the app, for the user to export and share when
/// something went wrong (Settings → Session Log). Every log record of every
/// logger from [level] up goes to a file. Each start moves the last run's
/// file to [previousFileName], replacing the one before, so the log holds
/// this run and the previous one: a run Android ended in the background (or
/// a crash) can still be exported after reopening the app. Fed by
/// [setUpLogging].
///
/// Lines go through [formatLogRecord], so credentials are masked before
/// they're written.
class SessionLog extends ChangeNotifier {
  SessionLog._();

  static final SessionLog instance = SessionLog._();

  /// The lowest level recorded. Release builds print only `INFO` and up to
  /// the console, but the session log is what a user can send, so it keeps
  /// the details too.
  static const Level level = Level.FINE;

  static const String fileName = 'session.log';
  static const String previousFileName = 'session.previous.log';

  /// When the file grows past this, it starts over, with the header again
  /// and a line saying so
  static const int defaultMaxBytes = 5 * 1024 * 1024;

  @visibleForTesting
  int maxBytes = defaultMaxBytes;

  // Lines logged before the file is open, written once it is. Bounded, in
  // case the file can't be opened at all.
  static const int _maxPending = 5000;

  final List<String> _pending = [];
  Future<void>? _started;
  RandomAccessFile? _file;
  String? _path;
  String? _previousPath;
  String _headerLine = '';
  bool _unavailable = false;
  int _bytes = 0;
  // Writes run one after the other
  Future<void> _writes = Future.value();

  /// Size of what this run has logged so far, in bytes
  int get sizeBytes => _bytes;

  /// Starts this run's log: keeps the last run's as the previous one,
  /// writes a header, then the lines logged so far. Once per process; later
  /// calls return the first one's future.
  Future<void> start() => _started ??= _start();

  Future<void> _start() async {
    final RandomAccessFile file;
    try {
      // Before the file is open: lines logged meanwhile are kept in
      // _pending, so they come after the header, in order
      _headerLine = '${await _header()}\n';
      final dir = await getApplicationDocumentsDirectory();
      await _removeReplayGainLog(dir);
      final path = '${dir.path}/$fileName';
      final previous = '${dir.path}/$previousFileName';
      final last = File(path);
      if (await last.exists()) {
        await last.rename(previous);
      } else {
        // No last run: an older previous one would pass for it
        final older = File(previous);
        if (await older.exists()) await older.delete();
      }
      file = await File(path).open(mode: FileMode.write);
      _path = path;
      _previousPath = previous;
    } catch (e) {
      _unavailable = true;
      _pending.clear();
      _log.warning('Could not open the session log', e);
      return;
    }
    // No await from here on: add() writes directly once _file is set
    _file = file;
    _enqueue(_headerLine);
    for (final line in _pending) {
      _enqueue(line);
    }
    _pending.clear();
  }

  /// The app's name and version for the header. On a device the first
  /// call goes over a platform channel and takes a while.
  @visibleForTesting
  Future<String> Function() appVersion = _appVersion;

  static Future<String> _appVersion() async {
    final info = await PackageInfo.fromPlatform();
    return 'Voidweaver ${info.version} (${info.buildNumber})';
  }

  Future<String> _header() async {
    var app = 'Voidweaver';
    try {
      app = await appVersion();
    } catch (_) {
      // Unknown version, still a usable log
    }
    final os = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    return '=== $app on $os, session started '
        '${DateTime.now().toIso8601String()} ===';
  }

  /// The log of the ReplayGain debug logging this log replaced, and its
  /// setting
  Future<void> _removeReplayGainLog(Directory dir) async {
    try {
      final old = File('${dir.path}/replaygain_debug.log');
      if (await old.exists()) await old.delete();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('replayGainDebugLoggingEnabled');
    } catch (e) {
      _log.fine('Could not remove the old ReplayGain log', e);
    }
  }

  /// Records [record] if it's at [level] or above.
  void add(LogRecord record) {
    if (record.level < level || _unavailable) return;
    final line =
        '${record.time.toIso8601String()}  ${formatLogRecord(record)}\n';
    if (_file == null) {
      if (_pending.length < _maxPending) _pending.add(line);
      return;
    }
    _enqueue(line);
  }

  void _enqueue(String line) {
    _writes = _writes.then((_) => _write(line)).catchError((Object e) {
      // Not through the log: it would come back here
      debugPrint('session_log: write failed: $e');
    });
  }

  Future<void> _write(String line) async {
    final file = _file;
    if (file == null) return;
    final bytes = utf8.encode(line);
    if (_bytes + bytes.length > maxBytes) {
      await file.truncate(0);
      await file.setPosition(0);
      _bytes = 0;
      final note = utf8.encode(
        '$_headerLine${DateTime.now().toIso8601String()}  === Size limit '
        'reached, earlier lines of this session dropped ===\n',
      );
      await file.writeFrom(note);
      _bytes += note.length;
    }
    await file.writeFrom(bytes);
    _bytes += bytes.length;
  }

  /// Completes when everything logged so far is written
  @visibleForTesting
  Future<void> flush() async {
    await _started;
    await _writes;
    await _file?.flush();
  }

  /// Empties the log, the previous run's included; it goes on with the
  /// lines logged from now on.
  Future<void> clear() async {
    await _started;
    final file = _file;
    final previous = _previousPath;
    _writes = _writes
        .then((_) async {
          if (file == null) return;
          await file.truncate(0);
          await file.setPosition(0);
          _bytes = 0;
          if (previous != null && await File(previous).exists()) {
            await File(previous).delete();
          }
        })
        .catchError((Object e) {
          _log.warning('Could not clear the session log', e);
        });
    await _writes;
    notifyListeners();
  }

  /// Size of the previous run's log, 0 if there's none
  Future<int> previousSizeBytes() async {
    final path = _previousPath;
    if (path == null) return 0;
    try {
      final file = File(path);
      return await file.exists() ? await file.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  /// Shares the log through the platform's share sheet (save to Files,
  /// mail, a chat app, ...). [sharePositionOrigin] anchors the sheet on
  /// tablets. Returns false if there's nothing to share, or sharing failed.
  Future<bool> export({Rect? sharePositionOrigin}) async {
    try {
      await flush();
      final path = _path;
      if (path == null) return false;
      final previous = _previousPath;
      final files = [
        if (previous != null && await previousSizeBytes() > 0)
          XFile(previous, mimeType: 'text/plain'),
        if (_bytes > 0) XFile(path, mimeType: 'text/plain'),
      ];
      if (files.isEmpty) return false;
      final result = await SharePlus.instance.share(
        ShareParams(
          files: files,
          subject: 'Voidweaver session log',
          sharePositionOrigin: sharePositionOrigin,
        ),
      );
      return result.status != ShareResultStatus.unavailable;
    } catch (e) {
      _log.warning('Could not export the session log', e);
      return false;
    }
  }

  /// Back to the state before [start], for tests: the singleton outlives
  /// each test.
  @visibleForTesting
  Future<void> resetForTest() async {
    await _writes;
    await _file?.close();
    _file = null;
    _path = null;
    _previousPath = null;
    _headerLine = '';
    _started = null;
    _unavailable = false;
    _bytes = 0;
    _pending.clear();
    _writes = Future.value();
    maxBytes = defaultMaxBytes;
    appVersion = _appVersion;
  }
}
