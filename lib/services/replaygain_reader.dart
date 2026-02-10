import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http_plus/http_plus.dart' as http;

class ReplayGainData {
  final double? trackGain;
  final double? albumGain;
  final double? trackPeak;
  final double? albumPeak;

  const ReplayGainData({
    this.trackGain,
    this.albumGain,
    this.trackPeak,
    this.albumPeak,
  });

  bool get hasAnyData =>
      trackGain != null ||
      albumGain != null ||
      trackPeak != null ||
      albumPeak != null;

  @override
  String toString() {
    return 'ReplayGainData(trackGain: $trackGain, albumGain: $albumGain, trackPeak: $trackPeak, albumPeak: $albumPeak)';
  }
}

class ReplayGainReader {
  static const int _maxHeaderSize = 256 * 1024; // Read first 256KB for metadata

  static Future<ReplayGainData> readFromUrl(String url) async {
    try {
      debugPrint('Reading ReplayGain metadata from: $url');

      // Make a range request to get just the beginning of the file
      final response = await http.get(
        Uri.parse(url),
        headers: {'Range': 'bytes=0-${_maxHeaderSize - 1}'},
      );

      if (response.statusCode != 206 && response.statusCode != 200) {
        debugPrint('Failed to fetch audio data: ${response.statusCode}');
        return const ReplayGainData();
      }

      final bytes = response.bodyBytes;
      if (bytes.isNotEmpty) {
        debugPrint(
            'Received ${bytes.length} bytes, first 16 bytes: ${bytes.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
        return _parseReplayGainFromBytes(bytes);
      } else {
        debugPrint('Received empty response');
        return const ReplayGainData();
      }
    } catch (e, stackTrace) {
      debugPrint('Error reading ReplayGain metadata: $e');
      debugPrint('Stack trace: $stackTrace');
      return const ReplayGainData();
    }
  }

  static ReplayGainData _parseReplayGainFromBytes(Uint8List bytes) {
    debugPrint('=== ReplayGain Parsing Started ===');
    debugPrint('File size: ${bytes.length} bytes');

    // Check file format first
    if (bytes.length >= 12) {
      // Check for MP4/M4A format (ftyp box)
      if (bytes[4] == 0x66 &&
          bytes[5] == 0x74 &&
          bytes[6] == 0x79 &&
          bytes[7] == 0x70) {
        debugPrint('Detected MP4/M4A file format');
        final mp4Data = _parseMP4Tags(bytes);
        if (mp4Data.hasAnyData) {
          debugPrint('✓ Found ReplayGain data in MP4 tags: $mp4Data');
          return mp4Data;
        } else {
          debugPrint('✗ No ReplayGain data in MP4 tags');
        }
      }
    }

    // Try to parse ID3v2 tags (MP3)
    debugPrint('Attempting ID3v2 tag parsing...');
    final id3Data = _parseID3v2Tags(bytes);
    if (id3Data.hasAnyData) {
      debugPrint('✓ Found ReplayGain data in ID3v2 tags: $id3Data');
      return id3Data;
    } else {
      debugPrint('✗ No ReplayGain data in ID3v2 tags');
    }

    // Try to parse APE tags
    debugPrint('Attempting APE tag parsing...');
    final apeData = _parseAPETags(bytes);
    if (apeData.hasAnyData) {
      debugPrint('✓ Found ReplayGain data in APE tags: $apeData');
      return apeData;
    } else {
      debugPrint('✗ No ReplayGain data in APE tags');
    }

    // Try to parse Vorbis comments (for FLAC/OGG)
    debugPrint('Attempting Vorbis comment parsing...');
    final vorbisData = _parseVorbisComments(bytes);
    if (vorbisData.hasAnyData) {
      debugPrint('✓ Found ReplayGain data in Vorbis comments: $vorbisData');
      return vorbisData;
    } else {
      debugPrint('✗ No ReplayGain data in Vorbis comments');
    }

    // Last resort: brute force search for ReplayGain strings anywhere in the data
    debugPrint('Attempting brute force search...');
    final bruteForceData = _bruteForceSearch(bytes);
    if (bruteForceData.hasAnyData) {
      debugPrint(
          '✓ Found ReplayGain data via brute force search: $bruteForceData');
      return bruteForceData;
    } else {
      debugPrint('✗ No ReplayGain data via brute force search');
    }

    debugPrint('⚠ WARNING: No ReplayGain metadata found after all parsing attempts!');
    debugPrint('=== ReplayGain Parsing Ended (NO DATA FOUND) ===');
    return const ReplayGainData();
  }

  static ReplayGainData _parseID3v2Tags(Uint8List bytes) {
    if (bytes.length < 10) return const ReplayGainData();

    // Check for ID3v2 header
    if (bytes[0] != 0x49 || bytes[1] != 0x44 || bytes[2] != 0x33) {
      return const ReplayGainData();
    }

    // Parse ID3v2 header
    final version = bytes[3];
    final revision = bytes[4];
    // final flags = bytes[5]; // Unused for now

    // Calculate tag size (synchsafe integer for v2.4, regular for v2.3)
    int tagSize;
    if (version >= 4) {
      tagSize =
          (bytes[6] << 21) | (bytes[7] << 14) | (bytes[8] << 7) | bytes[9];
    } else {
      // ID3v2.3 and earlier use regular integers
      tagSize =
          (bytes[6] << 21) | (bytes[7] << 14) | (bytes[8] << 7) | bytes[9];
    }
    tagSize += 10; // Include header size

    if (tagSize > bytes.length) {
      tagSize = bytes.length; // Use available data
    }

    debugPrint(
        'Found ID3v2.$version.$revision tag, size: $tagSize, available: ${bytes.length}');

    double? trackGain;
    double? albumGain;
    double? trackPeak;
    double? albumPeak;

    // Parse frames
    int offset = 10;
    while (offset + 10 < tagSize) {
      // Frame header
      final frameId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      offset += 4;

      // Frame size (depends on ID3v2 version)
      int frameSize;
      if (version >= 4) {
        // ID3v2.4 uses synchsafe integers
        frameSize = (bytes[offset] << 21) |
            (bytes[offset + 1] << 14) |
            (bytes[offset + 2] << 7) |
            bytes[offset + 3];
      } else {
        // ID3v2.3 uses regular integers
        frameSize = (bytes[offset] << 24) |
            (bytes[offset + 1] << 16) |
            (bytes[offset + 2] << 8) |
            bytes[offset + 3];
      }
      offset += 4;

      // final frameFlags = (bytes[offset] << 8) | bytes[offset + 1]; // Unused for now
      offset += 2;

      if (frameSize == 0 || offset + frameSize > tagSize) {
        break;
      }

      debugPrint('Found frame: $frameId, size: $frameSize');

      // Check for ReplayGain frames
      if (frameId == 'TXXX') {
        final frameData = bytes.sublist(offset, offset + frameSize);
        final replayGainData = _parseReplayGainTXXXFrame(frameData);
        if (replayGainData.trackGain != null) {
          trackGain = replayGainData.trackGain;
        }
        if (replayGainData.albumGain != null) {
          albumGain = replayGainData.albumGain;
        }
        if (replayGainData.trackPeak != null) {
          trackPeak = replayGainData.trackPeak;
        }
        if (replayGainData.albumPeak != null) {
          albumPeak = replayGainData.albumPeak;
        }
      }

      offset += frameSize;
    }

    return ReplayGainData(
      trackGain: trackGain,
      albumGain: albumGain,
      trackPeak: trackPeak,
      albumPeak: albumPeak,
    );
  }

  static ReplayGainData _parseReplayGainTXXXFrame(Uint8List frameData) {
    if (frameData.length < 2) return const ReplayGainData();

    final encoding = frameData[0];
    int offset = 1;

    String description;
    String value;

    // Handle different text encodings
    if (encoding == 1) {
      // UTF-16 with BOM
      // Find description (null-terminated, 2 bytes per char)
      int descEnd = offset;
      while (descEnd + 1 < frameData.length &&
          (frameData[descEnd] != 0 || frameData[descEnd + 1] != 0)) {
        descEnd += 2;
      }

      if (descEnd >= frameData.length) return const ReplayGainData();

      // Skip BOM if present and decode UTF-16
      int descStart = offset;
      if (descEnd - offset >= 2 &&
          frameData[offset] == 0xFF &&
          frameData[offset + 1] == 0xFE) {
        descStart += 2; // Skip BOM
      }

      try {
        description = utf8
            .decode(frameData.sublist(descStart, descEnd), allowMalformed: true)
            .toUpperCase();
      } catch (e) {
        description =
            String.fromCharCodes(frameData.sublist(descStart, descEnd))
                .toUpperCase();
      }

      offset = descEnd + 2; // Skip null terminator

      // Get value (rest of the frame)
      if (offset >= frameData.length) return const ReplayGainData();

      try {
        value =
            utf8.decode(frameData.sublist(offset), allowMalformed: true).trim();
      } catch (e) {
        value = String.fromCharCodes(frameData.sublist(offset)).trim();
      }
    } else {
      // ISO-8859-1 or ASCII (encoding == 0)
      // Find the description (null-terminated)
      int descEnd = offset;
      while (descEnd < frameData.length && frameData[descEnd] != 0) {
        descEnd++;
      }

      if (descEnd >= frameData.length) return const ReplayGainData();

      description = String.fromCharCodes(frameData.sublist(offset, descEnd))
          .toUpperCase();
      offset = descEnd + 1;

      // Get the value
      if (offset >= frameData.length) return const ReplayGainData();
      value = String.fromCharCodes(frameData.sublist(offset)).trim();
    }

    // Clean up the strings to avoid encoding issues in debug output
    final cleanDescription =
        description.replaceAll(RegExp(r'[^\x20-\x7E]'), '?');
    final cleanValue = value.replaceAll(RegExp(r'[^\x20-\x7E]'), '?');
    debugPrint('Found TXXX frame: $cleanDescription = $cleanValue');

    double? parseGain(String gainStr) {
      // Remove " dB" suffix and parse
      final cleanStr =
          gainStr.replaceAll(RegExp(r'\s*db\s*$', caseSensitive: false), '');
      return double.tryParse(cleanStr);
    }

    double? parsePeak(String peakStr) {
      return double.tryParse(peakStr);
    }

    switch (description) {
      case 'REPLAYGAIN_TRACK_GAIN':
        return ReplayGainData(trackGain: parseGain(value));
      case 'REPLAYGAIN_ALBUM_GAIN':
        return ReplayGainData(albumGain: parseGain(value));
      case 'REPLAYGAIN_TRACK_PEAK':
        return ReplayGainData(trackPeak: parsePeak(value));
      case 'REPLAYGAIN_ALBUM_PEAK':
        return ReplayGainData(albumPeak: parsePeak(value));
      default:
        return const ReplayGainData();
    }
  }

  static ReplayGainData _parseAPETags(Uint8List bytes) {
    // Look for APE tag at the end of the header section
    final apeSignature = 'APETAGEX'.codeUnits;

    for (int i = 0; i <= bytes.length - apeSignature.length; i++) {
      bool matches = true;
      for (int j = 0; j < apeSignature.length; j++) {
        if (bytes[i + j] != apeSignature[j]) {
          matches = false;
          break;
        }
      }

      if (matches) {
        debugPrint('Found APE tag at offset $i');
        return _parseAPETagItems(bytes, i);
      }
    }

    return const ReplayGainData();
  }

  static ReplayGainData _parseAPETagItems(Uint8List bytes, int tagOffset) {
    // Simple APE tag parsing - this is a basic implementation
    // Full APE parsing would require more complex logic

    double? trackGain;
    double? albumGain;
    double? trackPeak;
    double? albumPeak;

    // Search for ReplayGain keys in the remaining bytes
    final remainingBytes = bytes.sublist(tagOffset);
    final text = String.fromCharCodes(remainingBytes);

    final trackGainMatch = RegExp(r'REPLAYGAIN_TRACK_GAIN[^\d-]*(-?\d+\.?\d*)',
            caseSensitive: false)
        .firstMatch(text);
    if (trackGainMatch != null) {
      trackGain = double.tryParse(trackGainMatch.group(1)!);
    }

    final albumGainMatch = RegExp(r'REPLAYGAIN_ALBUM_GAIN[^\d-]*(-?\d+\.?\d*)',
            caseSensitive: false)
        .firstMatch(text);
    if (albumGainMatch != null) {
      albumGain = double.tryParse(albumGainMatch.group(1)!);
    }

    final trackPeakMatch =
        RegExp(r'REPLAYGAIN_TRACK_PEAK[^\d]*(\d+\.?\d*)', caseSensitive: false)
            .firstMatch(text);
    if (trackPeakMatch != null) {
      trackPeak = double.tryParse(trackPeakMatch.group(1)!);
    }

    final albumPeakMatch =
        RegExp(r'REPLAYGAIN_ALBUM_PEAK[^\d]*(\d+\.?\d*)', caseSensitive: false)
            .firstMatch(text);
    if (albumPeakMatch != null) {
      albumPeak = double.tryParse(albumPeakMatch.group(1)!);
    }

    return ReplayGainData(
      trackGain: trackGain,
      albumGain: albumGain,
      trackPeak: trackPeak,
      albumPeak: albumPeak,
    );
  }

  static ReplayGainData _parseVorbisComments(Uint8List bytes) {
    // Look for Vorbis comment block (for FLAC files)
    // This is a simplified implementation

    double? trackGain;
    double? albumGain;
    double? trackPeak;
    double? albumPeak;

    // Convert to string and search for ReplayGain comments
    final text = String.fromCharCodes(bytes);

    final trackGainMatch =
        RegExp(r'REPLAYGAIN_TRACK_GAIN=(-?\d+\.?\d*)', caseSensitive: false)
            .firstMatch(text);
    if (trackGainMatch != null) {
      trackGain = double.tryParse(trackGainMatch.group(1)!);
    }

    final albumGainMatch =
        RegExp(r'REPLAYGAIN_ALBUM_GAIN=(-?\d+\.?\d*)', caseSensitive: false)
            .firstMatch(text);
    if (albumGainMatch != null) {
      albumGain = double.tryParse(albumGainMatch.group(1)!);
    }

    final trackPeakMatch =
        RegExp(r'REPLAYGAIN_TRACK_PEAK=(\d+\.?\d*)', caseSensitive: false)
            .firstMatch(text);
    if (trackPeakMatch != null) {
      trackPeak = double.tryParse(trackPeakMatch.group(1)!);
    }

    final albumPeakMatch =
        RegExp(r'REPLAYGAIN_ALBUM_PEAK=(\d+\.?\d*)', caseSensitive: false)
            .firstMatch(text);
    if (albumPeakMatch != null) {
      albumPeak = double.tryParse(albumPeakMatch.group(1)!);
    }

    if (trackGain != null ||
        albumGain != null ||
        trackPeak != null ||
        albumPeak != null) {
      return ReplayGainData(
        trackGain: trackGain,
        albumGain: albumGain,
        trackPeak: trackPeak,
        albumPeak: albumPeak,
      );
    }

    return const ReplayGainData();
  }

  static ReplayGainData _parseMP4Tags(Uint8List bytes) {
    debugPrint('Parsing MP4/M4A metadata for ReplayGain tags');

    double? trackGain;
    double? albumGain;
    double? trackPeak;
    double? albumPeak;

    // Look for iTunes-style tags or other metadata in the atom structure
    int offset = 0;

    while (offset + 8 < bytes.length) {
      // Read atom size and type
      if (offset + 8 > bytes.length) break;

      final atomSize = (bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];

      if (atomSize < 8 || atomSize > bytes.length - offset) {
        break;
      }

      final atomType =
          String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
      debugPrint('Found MP4 atom: $atomType, size: $atomSize');

      // Look for metadata atoms
      if (atomType == 'moov' || atomType == 'udta' || atomType == 'meta') {
        // These contain metadata, search deeper
        final atomData = bytes.sublist(offset + 8, offset + atomSize);
        final nestedData = _searchMP4Metadata(atomData);
        if (nestedData.hasAnyData) {
          return nestedData;
        }
      }

      // Look for iTunes metadata atom 'ilst'
      if (atomType == 'ilst') {
        debugPrint('Found iTunes metadata atom');
        final metadataData = bytes.sublist(offset + 8, offset + atomSize);
        return _parseItunesMetadata(metadataData);
      }

      offset += atomSize;
    }

    // Also try searching for ReplayGain as text in the entire data
    final textData = String.fromCharCodes(bytes);

    // Look for common ReplayGain tag formats in M4A
    final trackGainMatch = RegExp(
            r'----:com\.apple\.iTunes:replaygain_track_gain[^\d-]*(-?\d+\.?\d*)',
            caseSensitive: false)
        .firstMatch(textData);
    if (trackGainMatch != null) {
      trackGain = double.tryParse(trackGainMatch.group(1)!);
      debugPrint('Found iTunes ReplayGain track gain: $trackGain');
    }

    final albumGainMatch = RegExp(
            r'----:com\.apple\.iTunes:replaygain_album_gain[^\d-]*(-?\d+\.?\d*)',
            caseSensitive: false)
        .firstMatch(textData);
    if (albumGainMatch != null) {
      albumGain = double.tryParse(albumGainMatch.group(1)!);
      debugPrint('Found iTunes ReplayGain album gain: $albumGain');
    }

    final trackPeakMatch = RegExp(
            r'----:com\.apple\.iTunes:replaygain_track_peak[^\d]*(\d+\.?\d*)',
            caseSensitive: false)
        .firstMatch(textData);
    if (trackPeakMatch != null) {
      trackPeak = double.tryParse(trackPeakMatch.group(1)!);
      debugPrint('Found iTunes ReplayGain track peak: $trackPeak');
    }

    final albumPeakMatch = RegExp(
            r'----:com\.apple\.iTunes:replaygain_album_peak[^\d]*(\d+\.?\d*)',
            caseSensitive: false)
        .firstMatch(textData);
    if (albumPeakMatch != null) {
      albumPeak = double.tryParse(albumPeakMatch.group(1)!);
      debugPrint('Found iTunes ReplayGain album peak: $albumPeak');
    }

    // Also look for standard ReplayGain fields without iTunes prefix
    if (trackGain == null) {
      final stdTrackGainMatch = RegExp(
              r'replaygain_track_gain[^\d-]*(-?\d+\.?\d*)',
              caseSensitive: false)
          .firstMatch(textData);
      if (stdTrackGainMatch != null) {
        trackGain = double.tryParse(stdTrackGainMatch.group(1)!);
        debugPrint('Found standard ReplayGain track gain: $trackGain');
      }
    }

    if (albumGain == null) {
      final stdAlbumGainMatch = RegExp(
              r'replaygain_album_gain[^\d-]*(-?\d+\.?\d*)',
              caseSensitive: false)
          .firstMatch(textData);
      if (stdAlbumGainMatch != null) {
        albumGain = double.tryParse(stdAlbumGainMatch.group(1)!);
        debugPrint('Found standard ReplayGain album gain: $albumGain');
      }
    }

    if (trackPeak == null) {
      final stdTrackPeakMatch = RegExp(
              r'replaygain_track_peak[^\d]*(\d+\.?\d*)',
              caseSensitive: false)
          .firstMatch(textData);
      if (stdTrackPeakMatch != null) {
        trackPeak = double.tryParse(stdTrackPeakMatch.group(1)!);
        debugPrint('Found standard ReplayGain track peak: $trackPeak');
      }
    }

    if (albumPeak == null) {
      final stdAlbumPeakMatch = RegExp(
              r'replaygain_album_peak[^\d]*(\d+\.?\d*)',
              caseSensitive: false)
          .firstMatch(textData);
      if (stdAlbumPeakMatch != null) {
        albumPeak = double.tryParse(stdAlbumPeakMatch.group(1)!);
        debugPrint('Found standard ReplayGain album peak: $albumPeak');
      }
    }

    return ReplayGainData(
      trackGain: trackGain,
      albumGain: albumGain,
      trackPeak: trackPeak,
      albumPeak: albumPeak,
    );
  }

  static ReplayGainData _searchMP4Metadata(Uint8List bytes) {
    // Recursively search for metadata in nested MP4 atoms
    int offset = 0;

    while (offset + 8 < bytes.length) {
      if (offset + 8 > bytes.length) break;

      final atomSize = (bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];

      if (atomSize < 8 || atomSize > bytes.length - offset) {
        break;
      }

      final atomType =
          String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));

      if (atomType == 'ilst') {
        debugPrint('Found nested iTunes metadata atom');
        final metadataData = bytes.sublist(offset + 8, offset + atomSize);
        return _parseItunesMetadata(metadataData);
      }

      offset += atomSize;
    }

    return const ReplayGainData();
  }

  static ReplayGainData _parseItunesMetadata(Uint8List bytes) {
    debugPrint('Parsing iTunes metadata block');

    // Convert to string and search for ReplayGain fields
    final textData = String.fromCharCodes(bytes);
    debugPrint(
        'iTunes metadata text sample: ${textData.substring(0, math.min(200, textData.length))}');

    double? trackGain;
    double? albumGain;
    double? trackPeak;
    double? albumPeak;

    // Look for iTunes-style ReplayGain tags
    final patterns = [
      'replaygain_track_gain',
      'replaygain_album_gain',
      'replaygain_track_peak',
      'replaygain_album_peak',
      'REPLAYGAIN_TRACK_GAIN',
      'REPLAYGAIN_ALBUM_GAIN',
      'REPLAYGAIN_TRACK_PEAK',
      'REPLAYGAIN_ALBUM_PEAK',
    ];

    for (final pattern in patterns) {
      final regex =
          RegExp('$pattern[^\\d-]*(-?\\d+\\.?\\d*)', caseSensitive: false);
      final match = regex.firstMatch(textData);
      if (match != null) {
        final value = double.tryParse(match.group(1)!);
        final lowerPattern = pattern.toLowerCase();

        if (lowerPattern.contains('track_gain')) {
          trackGain = value;
          debugPrint('Found iTunes track gain: $trackGain');
        } else if (lowerPattern.contains('album_gain')) {
          albumGain = value;
          debugPrint('Found iTunes album gain: $albumGain');
        } else if (lowerPattern.contains('track_peak')) {
          trackPeak = value;
          debugPrint('Found iTunes track peak: $trackPeak');
        } else if (lowerPattern.contains('album_peak')) {
          albumPeak = value;
          debugPrint('Found iTunes album peak: $albumPeak');
        }
      }
    }

    return ReplayGainData(
      trackGain: trackGain,
      albumGain: albumGain,
      trackPeak: trackPeak,
      albumPeak: albumPeak,
    );
  }

  static ReplayGainData _bruteForceSearch(Uint8List bytes) {
    try {
      debugPrint('Performing brute force search for ReplayGain metadata');

      // Convert bytes to string with error handling
      String textData;
      try {
        textData = utf8.decode(bytes, allowMalformed: true);
      } catch (e) {
        // Fallback to basic string conversion, filtering out problematic bytes
        final filteredBytes = bytes
            .where((b) => b >= 32 && b <= 126 || b == 10 || b == 13)
            .toList();
        textData = String.fromCharCodes(filteredBytes);
      }

      double? trackGain;
      double? albumGain;
      double? trackPeak;
      double? albumPeak;

      // Comprehensive search patterns for all possible ReplayGain tag formats
      final patterns = [
        // Standard ReplayGain patterns
        RegExp(r'replaygain_track_gain[^-\d]*(-?\d+\.?\d*)',
            caseSensitive: false),
        RegExp(r'replaygain_album_gain[^-\d]*(-?\d+\.?\d*)',
            caseSensitive: false),
        RegExp(r'replaygain_track_peak[^\d]*(\d+\.?\d*)', caseSensitive: false),
        RegExp(r'replaygain_album_peak[^\d]*(\d+\.?\d*)', caseSensitive: false),

        // iTunes format
        RegExp(
            r'----:com\.apple\.iTunes:replaygain_track_gain[^-\d]*(-?\d+\.?\d*)',
            caseSensitive: false),
        RegExp(
            r'----:com\.apple\.iTunes:replaygain_album_gain[^-\d]*(-?\d+\.?\d*)',
            caseSensitive: false),
        RegExp(
            r'----:com\.apple\.iTunes:replaygain_track_peak[^\d]*(\d+\.?\d*)',
            caseSensitive: false),
        RegExp(
            r'----:com\.apple\.iTunes:replaygain_album_peak[^\d]*(\d+\.?\d*)',
            caseSensitive: false),

        // Uppercase variants
        RegExp(r'REPLAYGAIN_TRACK_GAIN[^-\d]*(-?\d+\.?\d*)',
            caseSensitive: false),
        RegExp(r'REPLAYGAIN_ALBUM_GAIN[^-\d]*(-?\d+\.?\d*)',
            caseSensitive: false),
        RegExp(r'REPLAYGAIN_TRACK_PEAK[^\d]*(\d+\.?\d*)', caseSensitive: false),
        RegExp(r'REPLAYGAIN_ALBUM_PEAK[^\d]*(\d+\.?\d*)', caseSensitive: false),

        // Alternative formats (MusicBrainz, foobar2000, etc.)
        RegExp(r'RG_TRACK_GAIN[^-\d]*(-?\d+\.?\d*)', caseSensitive: false),
        RegExp(r'RG_ALBUM_GAIN[^-\d]*(-?\d+\.?\d*)', caseSensitive: false),
        RegExp(r'RG_TRACK_PEAK[^\d]*(\d+\.?\d*)', caseSensitive: false),
        RegExp(r'RG_ALBUM_PEAK[^\d]*(\d+\.?\d*)', caseSensitive: false),

        // MP3Gain format
        RegExp(r'mp3gain_track_gain[^-\d]*(-?\d+\.?\d*)', caseSensitive: false),
        RegExp(r'mp3gain_album_gain[^-\d]*(-?\d+\.?\d*)', caseSensitive: false),

        // R128 loudness (newer standard)
        RegExp(r'r128_track_gain[^-\d]*(-?\d+\.?\d*)', caseSensitive: false),
        RegExp(r'r128_album_gain[^-\d]*(-?\d+\.?\d*)', caseSensitive: false),
      ];

      for (final pattern in patterns) {
        final match = pattern.firstMatch(textData);
        if (match != null) {
          final value = double.tryParse(match.group(1)!);
          final patternStr = pattern.pattern.toLowerCase();

          debugPrint('Brute force found: ${match.group(0)} -> value: $value');

          if (patternStr.contains('track_gain') ||
              patternStr.contains('track_gain')) {
            trackGain ??= value; // Only set if not already found
          } else if (patternStr.contains('album_gain')) {
            albumGain ??= value;
          } else if (patternStr.contains('track_peak')) {
            trackPeak ??= value;
          } else if (patternStr.contains('album_peak')) {
            albumPeak ??= value;
          }
        }
      }

      // Also search for numeric patterns near "dB" that might be ReplayGain values
      final dbPatterns = [
        RegExp(r'(-?\d+\.?\d*)\s*db', caseSensitive: false),
        RegExp(r'(-?\d+\.?\d*)\s*lufs', caseSensitive: false), // R128 loudness
      ];

      for (final pattern in dbPatterns) {
        final matches = pattern.allMatches(textData);
        for (final match in matches) {
          final value = double.tryParse(match.group(1)!);
          if (value != null && value >= -30 && value <= 15) {
            // Reasonable ReplayGain range
            debugPrint(
                'Found potential ReplayGain value: ${match.group(0)} -> $value');

            // If we haven't found any gains yet, use this as track gain
            if (trackGain == null && albumGain == null) {
              trackGain = value;
              debugPrint('Assigned as track gain: $value');
              break; // Only take the first reasonable value
            }
          }
        }
      }

      return ReplayGainData(
        trackGain: trackGain,
        albumGain: albumGain,
        trackPeak: trackPeak,
        albumPeak: albumPeak,
      );
    } catch (e, stackTrace) {
      debugPrint('Error in brute force search: $e');
      debugPrint('Stack trace: $stackTrace');
      return const ReplayGainData();
    }
  }
}
