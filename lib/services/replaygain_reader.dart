import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'replaygain/ape.dart';
import 'replaygain/header_size.dart' as header_size;
import 'replaygain/id3v2.dart';
import 'replaygain/mp4.dart';
import 'replaygain/reader_log.dart';
import 'replaygain/replaygain_data.dart';
import 'replaygain/url_head.dart';
import 'replaygain/vorbis.dart';
import 'replaygain_debug_logger.dart';

export 'replaygain/replaygain_data.dart';

/// Reads ReplayGain tags from the start of a file, over the network or from
/// disk. The parsers for each tag format are in `replaygain/`.
class ReplayGainReader {
  static const int _maxHeaderSize = 256 * 1024; // Read first 256KB for metadata

  /// Gives up on reading the tags over the network after this long, see
  /// [readFromUrl].
  static const Duration defaultUrlTimeout = Duration(seconds: 3);

  /// Reads ReplayGain metadata from the start of the file at [url] through
  /// [client] (see `SubsonicApi.readReplayGain`). If the server refuses [url]
  /// (an error status, or a Subsonic error response instead of audio), reads
  /// from [fallbackUrl] instead. Playback waits for this, so after [timeout]
  /// (for both) it gives up and returns no data (the fallback gain applies)
  /// rather than hold it up on a stalled connection.
  static Future<ReplayGainData> readFromUrl(String url,
      {required http.Client client,
      String? fallbackUrl,
      Duration timeout = defaultUrlTimeout}) async {
    UrlHead? head;
    var timedOut = false;
    Future<ReplayGainData> read() async {
      for (final candidate in [url, if (fallbackUrl != null) fallbackUrl]) {
        if (timedOut) break;
        readerLog(() => 'Reading ReplayGain metadata from: $candidate');
        final current = head = UrlHead(client, candidate);
        try {
          final data = await readFromHead(current.read);
          if (!current.refused) return data;
        } finally {
          await current.close();
        }
        readerLog(() => 'The server refused the request');
      }
      return const ReplayGainData();
    }

    try {
      return await read().timeout(timeout);
    } on TimeoutException {
      readerLog(() => 'Reading ReplayGain metadata timed out after $timeout');
      timedOut = true;
      await head?.close();
      return const ReplayGainData();
    } catch (e, stackTrace) {
      readerLog(() => 'Error reading ReplayGain metadata: $e');
      readerLog(() => 'Stack trace: $stackTrace');
      return const ReplayGainData();
    }
  }

  /// Reads ReplayGain metadata from the start of a local file.
  static Future<ReplayGainData> readFromFile(File file) async {
    readerLog(() => 'Reading ReplayGain metadata from file: ${file.path}');
    try {
      final raf = await file.open();
      try {
        return await readFromHead((length) async {
          await raf.setPosition(0);
          return raf.read(length);
        });
      } finally {
        await raf.close();
      }
    } catch (e) {
      readerLog(() => 'Error reading ReplayGain metadata from file: $e');
      return const ReplayGainData();
    }
  }

  /// Reads ReplayGain metadata through [readHead], which returns up to the
  /// given number of bytes from the start of the audio (null if unavailable).
  /// Reads more if the tags extend past the first 256 KB.
  static Future<ReplayGainData> readFromHead(
      Future<Uint8List?> Function(int length) readHead) async {
    try {
      final head = await readHead(_maxHeaderSize);
      if (head == null || head.isEmpty) return const ReplayGainData();
      var bytes = head;
      readerLog(() => 'Received ${bytes.length} bytes, first 16 bytes: '
          '${bytes.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
      // FLAC blocks and MP4 atoms reveal the next one's position only once
      // they are read, so this can take several steps
      for (var required = requiredHeaderSize(bytes);
          required > bytes.length;
          required = requiredHeaderSize(bytes)) {
        readerLog(
            () => 'Metadata extends to $required bytes, reading the rest');
        final more = await readHead(required);
        if (more == null || more.length <= bytes.length) break;
        bytes = more;
      }
      return await _parseInBackground(bytes);
    } catch (e) {
      readerLog(() => 'Error reading ReplayGain metadata: $e');
      return const ReplayGainData();
    }
  }

  /// See [header_size.requiredHeaderSize].
  @visibleForTesting
  static int requiredHeaderSize(Uint8List bytes) =>
      header_size.requiredHeaderSize(bytes);

  @visibleForTesting
  static ReplayGainData parseBytes(Uint8List bytes) => _parse(bytes);

  /// Parses [bytes] on a background isolate: they can be up to
  /// [header_size.maxMetadataSize], and a file without ReplayGain tags is
  /// searched by every parser in turn (byte scans, the whole buffer as a
  /// string), which would stall the UI at every track start and prefetch.
  /// The lines logged meanwhile are logged here afterwards. Static, so the
  /// closure sent to the isolate can't capture the caller's (an HTTP client,
  /// an open file).
  static Future<ReplayGainData> _parseInBackground(Uint8List bytes) async {
    final logging = replayGainLogging;
    final (data, lines) =
        await Isolate.run(() => collectReaderLog(logging, () => _parse(bytes)));
    for (final line in lines ?? const <String>[]) {
      logReplayGain(() => line);
    }
    return data;
  }

  /// Tries each tag format in turn and returns the first one with any data.
  static ReplayGainData _parse(Uint8List bytes) {
    readerLog(() => '=== ReplayGain Parsing Started ===');
    readerLog(() => 'File size: ${bytes.length} bytes');

    if (isMp4(bytes)) {
      readerLog(() => 'Detected MP4/M4A file format');
      final mp4Data = parseMp4(bytes);
      if (mp4Data.hasAnyData) {
        readerLog(() => '✓ Found ReplayGain data in MP4 tags: $mp4Data');
        return mp4Data;
      }
      readerLog(() => '✗ No ReplayGain data in MP4 tags');
    }

    for (final (name, parse) in const [
      ('ID3v2 tags', parseId3v2),
      ('APE tags', parseApe),
      ('Vorbis comments', parseVorbisComments),
    ]) {
      readerLog(() => 'Looking for $name...');
      final data = parse(bytes);
      if (data.hasAnyData) {
        readerLog(() => '✓ Found ReplayGain data in $name: $data');
        return data;
      }
      readerLog(() => '✗ No ReplayGain data in $name');
    }

    readerLog(() =>
        '⚠ WARNING: No ReplayGain metadata found after all parsing attempts!');
    readerLog(() => '=== ReplayGain Parsing Ended (NO DATA FOUND) ===');
    return const ReplayGainData();
  }
}
