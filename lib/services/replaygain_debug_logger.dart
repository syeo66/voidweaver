import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Captures detailed ReplayGain diagnostic events (stream URLs, parsed
/// metadata, computed volume, errors) to a log file on disk so playback
/// issues can be reproduced and the log shared for troubleshooting.
///
/// Disabled by default. When disabled, [log] is a no-op so call sites can
/// log unconditionally without a performance cost.
class ReplayGainDebugLogger extends ChangeNotifier {
  static final ReplayGainDebugLogger instance =
      ReplayGainDebugLogger._internal();

  ReplayGainDebugLogger._internal();

  static const String _enabledPrefKey = 'replayGainDebugLoggingEnabled';
  static const String _logFileName = 'replaygain_debug.log';
  static const int _maxLogBytes = 5 * 1024 * 1024; // 5MB
  static const int _maxMemoryLines = 500;

  bool _enabled = false;
  File? _logFile;
  int _bytesWritten = 0;
  Future<void> _writeQueue = Future.value();
  final List<String> _memoryBuffer = [];

  bool get enabled => _enabled;

  /// Most recent log lines, newest last. Kept in memory for a quick
  /// in-app preview without reading the file back from disk.
  List<String> get recentEntries => List.unmodifiable(_memoryBuffer);

  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_enabledPrefKey) ?? false;
    } catch (e) {
      debugPrint('[ReplayGainDebugLogger] Failed to load settings: $e');
    }

    try {
      final file = await _ensureLogFile();
      if (await file.exists()) {
        _bytesWritten = await file.length();
      }
    } catch (e) {
      debugPrint('[ReplayGainDebugLogger] Failed to access log file: $e');
    }
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledPrefKey, value);
    } catch (e) {
      debugPrint('[ReplayGainDebugLogger] Failed to persist setting: $e');
    }

    if (value) {
      log('=== Debug logging enabled ===');
    }
  }

  /// Redacts Subsonic auth query parameters (username/token/salt) from a
  /// URL before it is written to the log, since the log file is meant to
  /// be exported and shared outside the device.
  static String redact(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.queryParameters.isEmpty) return url;

      final sanitized = <String, String>{};
      for (final entry in uri.queryParameters.entries) {
        sanitized[entry.key] =
            (entry.key == 'u' || entry.key == 't' || entry.key == 's')
                ? '[REDACTED]'
                : entry.value;
      }
      return uri.replace(queryParameters: sanitized).toString();
    } catch (_) {
      return url;
    }
  }

  /// Appends a line to the debug log. No-op unless [enabled].
  void log(String message) {
    if (!_enabled) return;

    final line = '${DateTime.now().toIso8601String()}  $message';

    _memoryBuffer.add(line);
    if (_memoryBuffer.length > _maxMemoryLines) {
      _memoryBuffer.removeAt(0);
    }

    _writeQueue = _writeQueue.then((_) => _appendLine(line)).catchError((e) {
      debugPrint('[ReplayGainDebugLogger] Write failed: $e');
    });
  }

  Future<void> _appendLine(String line) async {
    final file = await _ensureLogFile();
    final bytes = utf8.encode('$line\n');

    if (_bytesWritten + bytes.length > _maxLogBytes) {
      await file.writeAsString(
        '${DateTime.now().toIso8601String()}  '
        '=== Log rotated: size limit reached, older entries discarded ===\n',
      );
      _bytesWritten = 0;
    }

    await file.writeAsBytes(bytes, mode: FileMode.append, flush: false);
    _bytesWritten += bytes.length;
  }

  Future<File> _ensureLogFile() async {
    if (_logFile != null) return _logFile!;
    final dir = await getApplicationDocumentsDirectory();
    _logFile = File('${dir.path}/$_logFileName');
    return _logFile!;
  }

  /// Current size of the log file on disk, in bytes.
  Future<int> sizeBytes() async {
    try {
      final file = await _ensureLogFile();
      if (!await file.exists()) return 0;
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  /// Clears the log file and in-memory buffer.
  Future<void> clear() async {
    await _writeQueue;
    _memoryBuffer.clear();
    _bytesWritten = 0;
    try {
      final file = await _ensureLogFile();
      if (await file.exists()) {
        await file.writeAsString('');
      }
    } catch (e) {
      debugPrint('[ReplayGainDebugLogger] Failed to clear log: $e');
    }
    notifyListeners();
  }

  /// Shares the log file via the platform share sheet so it can be saved
  /// to Files, sent over email/AirDrop/Messages, etc.
  ///
  /// [sharePositionOrigin] anchors the share sheet popover on iPad; without
  /// it, sharing can fail or crash on that platform.
  ///
  /// Returns false if there is nothing to share yet, or sharing failed.
  Future<bool> exportLog({Rect? sharePositionOrigin}) async {
    await _writeQueue;
    try {
      final file = await _ensureLogFile();
      if (!await file.exists() || await file.length() == 0) {
        return false;
      }

      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'Voidweaver ReplayGain Debug Log',
          text: 'Voidweaver ReplayGain debug log',
          sharePositionOrigin: sharePositionOrigin,
        ),
      );
      return result.status == ShareResultStatus.success ||
          result.status == ShareResultStatus.dismissed;
    } catch (e) {
      debugPrint('[ReplayGainDebugLogger] Export failed: $e');
      return false;
    }
  }
}
