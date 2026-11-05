import 'dart:math' as math;
import 'dart:typed_data';

import 'reader_log.dart';
import 'replaygain_data.dart';

/// Whether [bytes] start like an MP4/M4A file (an 'ftyp' box).
bool isMp4(Uint8List bytes) =>
    bytes.length >= 12 &&
    bytes[4] == 0x66 &&
    bytes[5] == 0x74 &&
    bytes[6] == 0x79 &&
    bytes[7] == 0x70;

/// ReplayGain from the iTunes metadata ('ilst') of an MP4/M4A file, or from
/// ReplayGain keys anywhere in [bytes] if there is no 'ilst' atom.
ReplayGainData parseMp4(Uint8List bytes) {
  readerLog(() => 'Parsing MP4/M4A metadata for ReplayGain tags');

  double? trackGain;
  double? albumGain;
  double? trackPeak;
  double? albumPeak;

  // Look for iTunes-style tags or other metadata in the atom structure
  int offset = 0;

  while (offset + 8 < bytes.length) {
    final atomSize =
        (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];

    if (atomSize < 8 || atomSize > bytes.length - offset) {
      break;
    }

    final atomType = String.fromCharCodes(
      bytes.sublist(offset + 4, offset + 8),
    );
    readerLog(() => 'Found MP4 atom: $atomType, size: $atomSize');

    // Look for metadata atoms
    if (atomType == 'moov' || atomType == 'udta' || atomType == 'meta') {
      // These contain metadata, search deeper
      final atomData = bytes.sublist(offset + 8, offset + atomSize);
      final nestedData = _searchMp4Metadata(atomData);
      if (nestedData.hasAnyData) {
        return nestedData;
      }
    }

    // Look for iTunes metadata atom 'ilst'
    if (atomType == 'ilst') {
      readerLog(() => 'Found iTunes metadata atom');
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
    caseSensitive: false,
  ).firstMatch(textData);
  if (trackGainMatch != null) {
    trackGain = double.tryParse(trackGainMatch.group(1)!);
    readerLog(() => 'Found iTunes ReplayGain track gain: $trackGain');
  }

  final albumGainMatch = RegExp(
    r'----:com\.apple\.iTunes:replaygain_album_gain[^\d-]*(-?\d+\.?\d*)',
    caseSensitive: false,
  ).firstMatch(textData);
  if (albumGainMatch != null) {
    albumGain = double.tryParse(albumGainMatch.group(1)!);
    readerLog(() => 'Found iTunes ReplayGain album gain: $albumGain');
  }

  final trackPeakMatch = RegExp(
    r'----:com\.apple\.iTunes:replaygain_track_peak[^\d]*(\d+\.?\d*)',
    caseSensitive: false,
  ).firstMatch(textData);
  if (trackPeakMatch != null) {
    trackPeak = double.tryParse(trackPeakMatch.group(1)!);
    readerLog(() => 'Found iTunes ReplayGain track peak: $trackPeak');
  }

  final albumPeakMatch = RegExp(
    r'----:com\.apple\.iTunes:replaygain_album_peak[^\d]*(\d+\.?\d*)',
    caseSensitive: false,
  ).firstMatch(textData);
  if (albumPeakMatch != null) {
    albumPeak = double.tryParse(albumPeakMatch.group(1)!);
    readerLog(() => 'Found iTunes ReplayGain album peak: $albumPeak');
  }

  // Also look for standard ReplayGain fields without iTunes prefix
  if (trackGain == null) {
    final stdTrackGainMatch = RegExp(
      r'replaygain_track_gain[^\d-]*(-?\d+\.?\d*)',
      caseSensitive: false,
    ).firstMatch(textData);
    if (stdTrackGainMatch != null) {
      trackGain = double.tryParse(stdTrackGainMatch.group(1)!);
      readerLog(() => 'Found standard ReplayGain track gain: $trackGain');
    }
  }

  if (albumGain == null) {
    final stdAlbumGainMatch = RegExp(
      r'replaygain_album_gain[^\d-]*(-?\d+\.?\d*)',
      caseSensitive: false,
    ).firstMatch(textData);
    if (stdAlbumGainMatch != null) {
      albumGain = double.tryParse(stdAlbumGainMatch.group(1)!);
      readerLog(() => 'Found standard ReplayGain album gain: $albumGain');
    }
  }

  if (trackPeak == null) {
    final stdTrackPeakMatch = RegExp(
      r'replaygain_track_peak[^\d]*(\d+\.?\d*)',
      caseSensitive: false,
    ).firstMatch(textData);
    if (stdTrackPeakMatch != null) {
      trackPeak = double.tryParse(stdTrackPeakMatch.group(1)!);
      readerLog(() => 'Found standard ReplayGain track peak: $trackPeak');
    }
  }

  if (albumPeak == null) {
    final stdAlbumPeakMatch = RegExp(
      r'replaygain_album_peak[^\d]*(\d+\.?\d*)',
      caseSensitive: false,
    ).firstMatch(textData);
    if (stdAlbumPeakMatch != null) {
      albumPeak = double.tryParse(stdAlbumPeakMatch.group(1)!);
      readerLog(() => 'Found standard ReplayGain album peak: $albumPeak');
    }
  }

  return ReplayGainData(
    trackGain: trackGain,
    albumGain: albumGain,
    trackPeak: trackPeak,
    albumPeak: albumPeak,
  );
}

/// The 'ilst' atom directly inside [bytes] (the contents of a 'moov',
/// 'udta' or 'meta' atom), if there is one.
ReplayGainData _searchMp4Metadata(Uint8List bytes) {
  int offset = 0;

  while (offset + 8 < bytes.length) {
    final atomSize =
        (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];

    if (atomSize < 8 || atomSize > bytes.length - offset) {
      break;
    }

    final atomType = String.fromCharCodes(
      bytes.sublist(offset + 4, offset + 8),
    );

    if (atomType == 'ilst') {
      readerLog(() => 'Found nested iTunes metadata atom');
      final metadataData = bytes.sublist(offset + 8, offset + atomSize);
      return _parseItunesMetadata(metadataData);
    }

    offset += atomSize;
  }

  return const ReplayGainData();
}

ReplayGainData _parseItunesMetadata(Uint8List bytes) {
  readerLog(() => 'Parsing iTunes metadata block');

  // Convert to string and search for ReplayGain fields
  final textData = String.fromCharCodes(bytes);
  readerLog(
    () =>
        'iTunes metadata text sample: ${textData.substring(0, math.min(200, textData.length))}',
  );

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
    final regex = RegExp(
      '$pattern[^\\d-]*(-?\\d+\\.?\\d*)',
      caseSensitive: false,
    );
    final match = regex.firstMatch(textData);
    if (match != null) {
      final value = double.tryParse(match.group(1)!);
      final lowerPattern = pattern.toLowerCase();

      if (lowerPattern.contains('track_gain')) {
        trackGain = value;
        readerLog(() => 'Found iTunes track gain: $trackGain');
      } else if (lowerPattern.contains('album_gain')) {
        albumGain = value;
        readerLog(() => 'Found iTunes album gain: $albumGain');
      } else if (lowerPattern.contains('track_peak')) {
        trackPeak = value;
        readerLog(() => 'Found iTunes track peak: $trackPeak');
      } else if (lowerPattern.contains('album_peak')) {
        albumPeak = value;
        readerLog(() => 'Found iTunes album peak: $albumPeak');
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
