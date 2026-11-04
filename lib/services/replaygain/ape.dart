import 'dart:typed_data';

import 'reader_log.dart';
import 'replaygain_data.dart';

/// ReplayGain from the first APE tag found anywhere in [bytes].
ReplayGainData parseApe(Uint8List bytes) {
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
      readerLog(() => 'Found APE tag at offset $i');
      return _parseApeTagItems(bytes, i);
    }
  }

  return const ReplayGainData();
}

/// Searches the bytes from [tagOffset] on for the ReplayGain keys, rather
/// than walking the tag's items.
ReplayGainData _parseApeTagItems(Uint8List bytes, int tagOffset) {
  double? trackGain;
  double? albumGain;
  double? trackPeak;
  double? albumPeak;

  final remainingBytes = bytes.sublist(tagOffset);
  final text = String.fromCharCodes(remainingBytes);

  final trackGainMatch =
      RegExp(r'REPLAYGAIN_TRACK_GAIN[^\d-]*(-?\d+\.?\d*)', caseSensitive: false)
          .firstMatch(text);
  if (trackGainMatch != null) {
    trackGain = double.tryParse(trackGainMatch.group(1)!);
  }

  final albumGainMatch =
      RegExp(r'REPLAYGAIN_ALBUM_GAIN[^\d-]*(-?\d+\.?\d*)', caseSensitive: false)
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
