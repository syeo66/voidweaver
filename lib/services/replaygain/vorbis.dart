import 'dart:typed_data';

import 'replaygain_data.dart';

/// ReplayGain from Vorbis comments (FLAC, Ogg, Opus) anywhere in [bytes],
/// found by searching for the `KEY=value` strings rather than walking the
/// comment block. Falls back to the R128 gains for Opus.
ReplayGainData parseVorbisComments(Uint8List bytes) {
  double? trackGain;
  double? albumGain;
  double? trackPeak;
  double? albumPeak;

  final text = String.fromCharCodes(bytes);

  // Gains may carry an explicit sign, e.g. "+2.50 dB" (rsgain, foobar2000)
  final trackGainMatch = RegExp(
    r'REPLAYGAIN_TRACK_GAIN=([+-]?\d+\.?\d*)',
    caseSensitive: false,
  ).firstMatch(text);
  if (trackGainMatch != null) {
    trackGain = double.tryParse(trackGainMatch.group(1)!);
  }

  final albumGainMatch = RegExp(
    r'REPLAYGAIN_ALBUM_GAIN=([+-]?\d+\.?\d*)',
    caseSensitive: false,
  ).firstMatch(text);
  if (albumGainMatch != null) {
    albumGain = double.tryParse(albumGainMatch.group(1)!);
  }

  // Opus files often carry only R128 gains (RFC 7845)
  trackGain ??= _parseR128Gain(text, 'R128_TRACK_GAIN');
  albumGain ??= _parseR128Gain(text, 'R128_ALBUM_GAIN');

  final trackPeakMatch = RegExp(
    r'REPLAYGAIN_TRACK_PEAK=(\d+\.?\d*)',
    caseSensitive: false,
  ).firstMatch(text);
  if (trackPeakMatch != null) {
    trackPeak = double.tryParse(trackPeakMatch.group(1)!);
  }

  final albumPeakMatch = RegExp(
    r'REPLAYGAIN_ALBUM_PEAK=(\d+\.?\d*)',
    caseSensitive: false,
  ).firstMatch(text);
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

/// Parses an R128 gain tag and converts it to a ReplayGain-equivalent dB
/// value. R128 gains are Q7.8 fixed-point integers (1/256 dB) relative to
/// -23 LUFS, while ReplayGain 2.0 targets -18 LUFS, hence the +5 dB offset.
double? _parseR128Gain(String text, String key) {
  final match = RegExp(
    '$key=([+-]?\\d+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (match == null) return null;
  final q78 = int.tryParse(match.group(1)!);
  if (q78 == null) return null;
  return q78 / 256.0 + 5.0;
}
