import 'dart:typed_data';

import 'reader_log.dart';
import 'replaygain_data.dart';

/// ReplayGain from the TXXX frames of an ID3v2 tag at the start of [bytes]
/// (MP3, or a FLAC stream with an ID3v2 tag in front).
ReplayGainData parseId3v2(Uint8List bytes) {
  if (bytes.length < 10) return const ReplayGainData();

  // Check for ID3v2 header
  if (bytes[0] != 0x49 || bytes[1] != 0x44 || bytes[2] != 0x33) {
    return const ReplayGainData();
  }

  // Parse ID3v2 header
  final version = bytes[3];
  final revision = bytes[4];
  final flags = bytes[5];

  // The tag size is a synchsafe integer in every version, not counting the
  // 10 byte header
  var tagSize =
      (bytes[6] << 21) | (bytes[7] << 14) | (bytes[8] << 7) | bytes[9];
  tagSize += 10;

  if (tagSize > bytes.length) {
    tagSize = bytes.length; // Use available data
  }

  readerLog(() =>
      'Found ID3v2.$version.$revision tag, size: $tagSize, available: ${bytes.length}');

  double? trackGain;
  double? albumGain;
  double? trackPeak;
  double? albumPeak;

  // Parse frames, after the extended header if there is one
  int offset = 10;
  if (flags & 0x40 != 0 && bytes.length >= 14) {
    if (version >= 4) {
      // Synchsafe, counting its own size field
      offset +=
          (bytes[10] << 21) | (bytes[11] << 14) | (bytes[12] << 7) | bytes[13];
    } else {
      // A plain integer, not counting its own size field
      offset += 4 +
          ((bytes[10] << 24) |
              (bytes[11] << 16) |
              (bytes[12] << 8) |
              bytes[13]);
    }
  }
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

    // Frame flags, unused
    offset += 2;

    if (frameSize == 0 || offset + frameSize > tagSize) {
      break;
    }

    readerLog(() => 'Found frame: $frameId, size: $frameSize');

    // Check for ReplayGain frames
    if (frameId == 'TXXX') {
      final frameData = bytes.sublist(offset, offset + frameSize);
      final replayGainData = _parseTxxxFrame(frameData);
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

ReplayGainData _parseTxxxFrame(Uint8List frameData) {
  if (frameData.length < 2) return const ReplayGainData();

  final encoding = frameData[0];
  int offset = 1;

  String description;
  String value;

  // Handle different text encodings
  if (encoding == 1 || encoding == 2) {
    // UTF-16: with a BOM (1), or big-endian without one (2, ID3v2.4)
    // Find description (null-terminated, 2 bytes per char)
    int descEnd = offset;
    while (descEnd + 1 < frameData.length &&
        (frameData[descEnd] != 0 || frameData[descEnd + 1] != 0)) {
      descEnd += 2;
    }

    if (descEnd >= frameData.length) return const ReplayGainData();

    // Determine endianness and skip BOM if present
    int descStart = offset;
    // Without a BOM: little-endian for encoding 1, the most common in
    // ID3v2, big-endian for encoding 2
    bool isLittleEndian = encoding == 1;

    if (descEnd - offset >= 2) {
      if (frameData[offset] == 0xFF && frameData[offset + 1] == 0xFE) {
        isLittleEndian = true; // UTF-16 LE
        descStart += 2; // Skip BOM
      } else if (frameData[offset] == 0xFE && frameData[offset + 1] == 0xFF) {
        isLittleEndian = false; // UTF-16 BE
        descStart += 2; // Skip BOM
      }
    }

    // Decode UTF-16 description
    description = _decodeUtf16(
      frameData.sublist(descStart, descEnd),
      isLittleEndian,
    ).toUpperCase();

    offset = descEnd + 2; // Skip null terminator (2 bytes)

    // Get value (rest of the frame)
    if (offset >= frameData.length) return const ReplayGainData();

    // Check for BOM in value field
    int valueStart = offset;
    bool valueIsLittleEndian = isLittleEndian; // Inherit from description

    if (frameData.length - offset >= 2) {
      if (frameData[offset] == 0xFF && frameData[offset + 1] == 0xFE) {
        valueIsLittleEndian = true;
        valueStart += 2; // Skip BOM
      } else if (frameData[offset] == 0xFE && frameData[offset + 1] == 0xFF) {
        valueIsLittleEndian = false;
        valueStart += 2; // Skip BOM
      }
    }

    // Decode UTF-16 value
    value = _decodeUtf16(
      frameData.sublist(valueStart),
      valueIsLittleEndian,
    ).trim();
  } else {
    // ISO-8859-1 (0) or UTF-8 (3): the ReplayGain descriptions and values
    // are ASCII in both
    // Find the description (null-terminated)
    int descEnd = offset;
    while (descEnd < frameData.length && frameData[descEnd] != 0) {
      descEnd++;
    }

    if (descEnd >= frameData.length) return const ReplayGainData();

    description =
        String.fromCharCodes(frameData.sublist(offset, descEnd)).toUpperCase();
    offset = descEnd + 1;

    // Get the value
    if (offset >= frameData.length) return const ReplayGainData();
    value = String.fromCharCodes(frameData.sublist(offset)).trim();
  }

  // Clean up the strings to avoid encoding issues in debug output
  final cleanDescription = description.replaceAll(RegExp(r'[^\x20-\x7E]'), '?');
  final cleanValue = value.replaceAll(RegExp(r'[^\x20-\x7E]'), '?');
  readerLog(() => 'Found TXXX frame: $cleanDescription = $cleanValue');

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

/// Decodes UTF-16 encoded bytes to a String
///
/// ID3v2 uses UTF-16 for TXXX frames when encoding=1.
/// This helper properly decodes both Little Endian and Big Endian.
String _decodeUtf16(Uint8List bytes, bool isLittleEndian) {
  if (bytes.isEmpty) return '';

  // Ensure we have an even number of bytes (UTF-16 uses 2 bytes per char)
  final length = bytes.length - (bytes.length % 2);
  if (length == 0) return '';

  // Create a Uint16List view for proper UTF-16 decoding
  final buffer = bytes.buffer.asByteData();
  final chars = <int>[];

  for (int i = 0; i < length; i += 2) {
    final charCode = isLittleEndian
        ? buffer.getUint16(i, Endian.little)
        : buffer.getUint16(i, Endian.big);

    // Stop at null terminator
    if (charCode == 0) break;

    chars.add(charCode);
  }

  return String.fromCharCodes(chars);
}
