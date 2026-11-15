import 'dart:convert';
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

/// ReplayGain from the iTunes freeform items (`----`) of an MP4/M4A file,
/// in `moov/udta/meta/ilst`, where taggers write them. Each item holds a
/// `mean` box (`com.apple.iTunes`), a `name` box (`replaygain_track_gain`,
/// in any case) and a `data` box with the value as text (`-8.54 dB`,
/// `0.954132`).
///
/// A container box that runs past the end of [bytes] is read as far as it
/// goes; a `name` or `data` box must be complete, so a cut-off value is
/// never read as a shorter one.
ReplayGainData parseMp4(Uint8List bytes) {
  readerLog(() => 'Parsing MP4/M4A metadata for ReplayGain tags');
  final view = ByteData.sublistView(bytes);

  final moov = _child(view, 0, bytes.length, 'moov');
  if (moov == null) {
    readerLog(() => 'No moov box in the data read');
    return const ReplayGainData();
  }
  final udta = _child(view, moov.contentStart, moov.end, 'udta');
  final meta = udta == null
      ? null
      : _child(view, udta.contentStart, udta.end, 'meta');
  final ilst = meta == null
      ? null
      : _child(view, _metaChildrenStart(view, meta), meta.end, 'ilst');
  if (ilst == null) {
    readerLog(() => 'No moov/udta/meta/ilst box');
    return const ReplayGainData();
  }

  double? trackGain;
  double? albumGain;
  double? trackPeak;
  double? albumPeak;
  for (final item in _boxes(view, ilst.contentStart, ilst.end)) {
    if (item.type != '----') continue;
    final (name, value) = _freeformItem(view, item);
    if (name == null || value == null) continue;
    final number = _leadingNumber(value);
    readerLog(() => 'Found MP4 freeform item $name = "$value"');
    switch (name.toLowerCase()) {
      case 'replaygain_track_gain':
        trackGain ??= number;
      case 'replaygain_album_gain':
        albumGain ??= number;
      case 'replaygain_track_peak':
        trackPeak ??= number;
      case 'replaygain_album_peak':
        albumPeak ??= number;
    }
  }

  return ReplayGainData(
    trackGain: trackGain,
    albumGain: albumGain,
    trackPeak: trackPeak,
    albumPeak: albumPeak,
  );
}

/// Where the children of the `meta` box [meta] start. In MP4 files it's a
/// full box (4 bytes of version and flags before its children); QuickTime
/// writes it without them, starting right with its `hdlr` box.
int _metaChildrenStart(ByteData view, _Box meta) {
  final start = meta.contentStart;
  if (start + 8 <= meta.end && _typeAt(view, start + 4) == 'hdlr') {
    return start;
  }
  return start + 4;
}

/// The name and value of the freeform item [item]: the text of its `name`
/// box and of its first `data` box. Null for one that's missing or cut off.
(String?, String?) _freeformItem(ByteData view, _Box item) {
  String? name;
  String? value;
  for (final box in _boxes(view, item.contentStart, item.end)) {
    if (box.truncated) continue;
    switch (box.type) {
      case 'name':
        // A full box: version and flags before the text
        name ??= _text(view, box.contentStart + 4, box.end);
      case 'data':
        // The type of the value and its locale before it
        value ??= _text(view, box.contentStart + 8, box.end);
    }
  }
  return (name, value);
}

final _numberPattern = RegExp(r'^\s*([+-]?(?:\d+\.?\d*|\.\d+))');

/// The number [text] starts with, e.g. -8.54 for `-8.54 dB`
double? _leadingNumber(String text) {
  final match = _numberPattern.firstMatch(text);
  return match == null ? null : double.tryParse(match.group(1)!);
}

String? _text(ByteData view, int start, int end) {
  if (start > end) return null;
  return utf8.decode(
    Uint8List.sublistView(view, start, end),
    allowMalformed: true,
  );
}

String _typeAt(ByteData view, int offset) =>
    String.fromCharCodes(Uint8List.sublistView(view, offset, offset + 4));

/// The first box of [type] among the boxes from [start] to [end]
_Box? _child(ByteData view, int start, int end, String type) {
  for (final box in _boxes(view, start, end)) {
    if (box.type == type) return box;
  }
  return null;
}

/// The boxes one after the other from [start] to [end]. Stops at a header
/// that doesn't fit or is invalid. A box that runs past [end] is the last
/// one, cut off at [end] ([_Box.truncated]).
Iterable<_Box> _boxes(ByteData view, int start, int end) sync* {
  var offset = start;
  while (offset + 8 <= end) {
    var size = view.getUint32(offset);
    var headerSize = 8;
    if (size == 1) {
      // A 64-bit size after the type
      if (offset + 16 > end) return;
      size =
          view.getUint32(offset + 8) * 0x100000000 +
          view.getUint32(offset + 12);
      headerSize = 16;
    } else if (size == 0) {
      // Extends to the end of its parent (the file, for a top-level box)
      size = end - offset;
    }
    if (size < headerSize) return;
    final declaredEnd = offset + size;
    final truncated = declaredEnd > end;
    yield _Box(
      _typeAt(view, offset + 4),
      offset + headerSize,
      truncated ? end : declaredEnd,
      truncated: truncated,
    );
    if (truncated) return;
    offset = declaredEnd;
  }
}

/// A box of [type] whose content runs from [contentStart] to [end]
class _Box {
  final String type;
  final int contentStart;
  final int end;

  /// Whether the box runs past the data, which ends at [end]
  final bool truncated;

  _Box(this.type, this.contentStart, this.end, {required this.truncated});
}
