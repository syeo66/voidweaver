import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';

import '../models/subsonic_models.dart';
import '../utils/redact.dart';
import 'settings_service.dart';

final _log = Logger('replaygain');

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

  bool _enabled = false;
  File? _logFile;
  int _bytesWritten = 0;
  Future<void> _writeQueue = Future.value();

  bool get enabled => _enabled;

  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_enabledPrefKey) ?? false;
    } catch (e) {
      _log.warning('Debug log: Failed to load settings', e);
    }

    try {
      final file = await _ensureLogFile();
      if (await file.exists()) {
        _bytesWritten = await file.length();
      }
    } catch (e) {
      _log.warning('Debug log: Failed to access log file', e);
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
      _log.warning('Debug log: Failed to persist setting', e);
    }

    if (value) {
      log('=== Debug logging enabled ===');
    }
  }

  /// Appends a line to the debug log. No-op unless [enabled]. The log is
  /// meant to be shared, so credentials in URLs (also inside error messages)
  /// are masked here, see [redactCredentials].
  void log(String message) {
    if (!_enabled) return;

    final line =
        '${DateTime.now().toIso8601String()}  ${redactCredentials(message)}';

    _writeQueue = _writeQueue.then((_) => _appendLine(line)).catchError((
      Object e,
    ) {
      _log.warning('Debug log: Write failed', e);
    });
  }

  /// Completes when the lines logged so far are written
  @visibleForTesting
  Future<void> flush() => _writeQueue;

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

  /// Clears the log file.
  Future<void> clear() async {
    await _writeQueue;
    _bytesWritten = 0;
    try {
      final file = await _ensureLogFile();
      if (await file.exists()) {
        await file.writeAsString('');
      }
    } catch (e) {
      _log.warning('Debug log: Failed to clear log', e);
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
      _log.warning('Debug log: Export failed', e);
      return false;
    }
  }
}

/// Whether ReplayGain diagnostics are written anywhere: to the console when
/// the `replaygain` logger prints `FINE` (debug builds, see setUpLogging()),
/// or to the debug log when the user has enabled it in Settings. Neither is
/// on in a release build by default, so the lines aren't even built then.
bool get replayGainLogging =>
    _log.isLoggable(Level.FINE) || ReplayGainDebugLogger.instance.enabled;

/// Logs a ReplayGain diagnostic line to the console (`FINE`) and the debug
/// log. [message] is only called if [replayGainLogging] is on: ReplayGain
/// is read for every song played or prefetched.
void logReplayGain(String Function() message) {
  if (!replayGainLogging) return;
  final line = message();
  _log.fine(line);
  ReplayGainDebugLogger.instance.log(line);
}

/// The lines the ReplayGain debug log shows for the track that starts
/// playing: its ReplayGain data, the settings, and the linear [gain] it plays
/// at. [queue] is what the queue was started from (album gains are used in
/// smart mode only for albums).
List<String> trackGainReport(
  Song song,
  SettingsService settings, {
  required double gain,
  required String queue,
}) {
  String db(double? value) => '${value?.toStringAsFixed(2) ?? 'null'} dB';
  String peak(double? value) => value?.toStringAsFixed(4) ?? 'null';
  final rule = '='.padRight(80, '=');
  final ignored = [
    if (song.replayGainTrackGain != null &&
        SettingsService.plausibleGain(song.replayGainTrackGain) == null)
      'trackGain',
    if (song.replayGainAlbumGain != null &&
        SettingsService.plausibleGain(song.replayGainAlbumGain) == null)
      'albumGain',
    if (song.replayGainTrackPeak != null &&
        SettingsService.plausiblePeak(song.replayGainTrackPeak) == null)
      'trackPeak',
    if (song.replayGainAlbumPeak != null &&
        SettingsService.plausiblePeak(song.replayGainAlbumPeak) == null)
      'albumPeak',
  ];
  final usable =
      SettingsService.plausibleGain(song.replayGainTrackGain) != null ||
      SettingsService.plausibleGain(song.replayGainAlbumGain) != null;
  return [
    '',
    rule,
    '[ReplayGain] GAIN OF CURRENT TRACK',
    rule,
    '[ReplayGain] Song: "${song.title}" by "${song.artist}" (id=${song.id})',
    '[ReplayGain] Mode: ${settings.replayGainMode.name} (queue: $queue)',
    '[ReplayGain] TrackGain: ${db(song.replayGainTrackGain)}',
    '[ReplayGain] AlbumGain: ${db(song.replayGainAlbumGain)}',
    '[ReplayGain] TrackPeak: ${peak(song.replayGainTrackPeak)}',
    '[ReplayGain] AlbumPeak: ${peak(song.replayGainAlbumPeak)}',
    '[ReplayGain] Preamp: ${settings.replayGainPreamp.toStringAsFixed(1)} dB',
    '[ReplayGain] Fallback: '
        '${settings.replayGainFallbackGain.toStringAsFixed(1)} dB',
    '[ReplayGain] Prevent Clipping: ${settings.replayGainPreventClipping}',
    if (ignored.isNotEmpty)
      '[ReplayGain] Ignored, out of range: ${ignored.join(', ')}',
    '[ReplayGain] Source: ${usable ? 'METADATA' : 'FALLBACK'}',
    '[ReplayGain] Final Gain Multiplier: ${gain.toStringAsFixed(6)} '
        '(${(gain * 100).toStringAsFixed(2)}%)',
    rule,
    '',
  ];
}
