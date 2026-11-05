import 'dart:typed_data';

/// Upper bound when a tag is larger than the initial read (e.g. huge cover
/// art placed before the ReplayGain frames)
const int maxMetadataSize = 16 * 1024 * 1024;

/// Returns how many leading bytes are needed to cover the file's metadata,
/// based on the ID3v2 tag size, the FLAC metadata blocks up to the Vorbis
/// comment or the end of the MP4 'moov' atom. When [bytes] end before the
/// next FLAC block or MP4 atom header, that header is all it asks for, so
/// call again once it's read. Returns [bytes.length] when the size can't be
/// determined or is unreasonable.
int requiredHeaderSize(Uint8List bytes) {
  int required = bytes.length;

  if (bytes.length >= 10 &&
      bytes[0] == 0x49 &&
      bytes[1] == 0x44 &&
      bytes[2] == 0x33) {
    // ID3v2: synchsafe tag size + 10 byte header (+10 byte footer if flagged)
    final tagSize =
        (bytes[6] << 21) | (bytes[7] << 14) | (bytes[8] << 7) | bytes[9];
    final hasFooter = (bytes[5] & 0x10) != 0;
    required = tagSize + 10 + (hasFooter ? 10 : 0);
    // Some taggers put an ID3v2 tag in front of a FLAC stream
    if (required <= bytes.length) {
      required = _flacMetadataEnd(bytes, required) ?? bytes.length;
    }
  } else if (_flacMetadataEnd(bytes, 0) case final end?) {
    required = end;
  } else if (bytes.length >= 8 &&
      bytes[4] == 0x66 &&
      bytes[5] == 0x74 &&
      bytes[6] == 0x79 &&
      bytes[7] == 0x70) {
    // MP4: walk top-level atoms until 'moov' (only works when moov precedes
    // mdat, which is the case for files optimised for streaming)
    int offset = 0;
    while (offset + 8 <= bytes.length) {
      final atomSize =
          (bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      if (atomSize < 8) break;
      final atomType = String.fromCharCodes(
        bytes.sublist(offset + 4, offset + 8),
      );
      if (atomType == 'moov') {
        required = offset + atomSize;
        break;
      }
      if (atomType == 'mdat') break;
      offset += atomSize;
      // The next atom's header
      if (offset + 8 > bytes.length) required = offset + 8;
    }
  }

  if (required <= bytes.length || required > maxMetadataSize) {
    return bytes.length;
  }
  return required;
}

/// End of the FLAC metadata blocks up to and including the Vorbis comment
/// (all of them if there is none), for a FLAC stream at [start]. If [bytes]
/// end before that, the end of the next block header. Null if there is no
/// FLAC stream at [start].
int? _flacMetadataEnd(Uint8List bytes, int start) {
  if (bytes.length < start + 4 ||
      bytes[start] != 0x66 || // fLaC
      bytes[start + 1] != 0x4c ||
      bytes[start + 2] != 0x61 ||
      bytes[start + 3] != 0x43) {
    return null;
  }
  var offset = start + 4;
  while (offset + 4 <= bytes.length) {
    final isLast = (bytes[offset] & 0x80) != 0;
    final type = bytes[offset] & 0x7f;
    final end =
        offset +
        4 +
        ((bytes[offset + 1] << 16) |
            (bytes[offset + 2] << 8) |
            bytes[offset + 3]);
    if (type == 4 || isLast) return end; // 4: VORBIS_COMMENT
    offset = end;
  }
  return offset + 4;
}
