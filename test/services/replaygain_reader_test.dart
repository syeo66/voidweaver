import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/replaygain_reader.dart';
import 'package:voidweaver/services/settings_service.dart';

/// Loads a gzipped header fixture taken from a real file. Layout and sizes
/// are kept intact, but cover art (and for MP4, the track sample tables) are
/// zeroed out and no audio data is included:
/// - MP3: the full ID3v2 tag plus the first MPEG frame (LAME/Info header)
/// - M4A: everything up to the end of 'moov' plus the 'mdat' atom header
Uint8List loadFixture(String name, {String ext = 'mp3'}) {
  final file = File('test/fixtures/replaygain/$name.$ext.gz');
  return Uint8List.fromList(gzip.decode(file.readAsBytesSync()));
}

Future<File> writeTempFile(Uint8List bytes, String name) async {
  final dir = await Directory.systemTemp.createTemp('rg_reader_test');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes);
  return file;
}

Uint8List ascii(String s) => Uint8List.fromList(s.codeUnits);

List<int> txxxFrame(String description, String value) {
  final body = [0, ...description.codeUnits, 0, ...value.codeUnits];
  final n = body.length;
  return [
    ...'TXXX'.codeUnits,
    (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, //
    0, 0,
    ...body,
  ];
}

Uint8List id3v23(List<int> frames) {
  final n = frames.length;
  return Uint8List.fromList([
    ...'ID3'.codeUnits, 3, 0, 0, //
    (n >> 21) & 0x7f, (n >> 14) & 0x7f, (n >> 7) & 0x7f, n & 0x7f,
    ...frames,
  ]);
}

List<int> flacBlock(int type, List<int> data, {bool last = false}) {
  final n = data.length;
  return [
    (last ? 0x80 : 0) | type, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, //
    ...data,
  ];
}

/// FLAC metadata whose cover art (a PICTURE block of [pictureSize] bytes)
/// comes before the Vorbis comment, followed by some audio frames
Uint8List flacWithCover(int pictureSize, String comment) => Uint8List.fromList([
      ...'fLaC'.codeUnits,
      ...flacBlock(0, List.filled(34, 0)), // STREAMINFO
      ...flacBlock(6, List.filled(pictureSize, 0)), // PICTURE
      ...flacBlock(4, comment.codeUnits, last: true), // VORBIS_COMMENT
      ...List.filled(64 * 1024, 0xff),
    ]);

/// A TXXX frame of ID3v2.3 (plain sizes) or, with [v24], ID3v2.4 (synchsafe
/// sizes), with the description and value already encoded as [body]
List<int> rawTxxxFrame(List<int> body, {bool v24 = false}) {
  final n = body.length;
  return [
    ...'TXXX'.codeUnits,
    ...(v24
        ? synchsafe(n)
        : [(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]),
    0,
    0,
    ...body,
  ];
}

List<int> synchsafe(int n) =>
    [(n >> 21) & 0x7f, (n >> 14) & 0x7f, (n >> 7) & 0x7f, n & 0x7f];

/// UTF-16 text, little-endian unless [bigEndian], with a BOM if [bom]
List<int> utf16(String s, {bool bigEndian = false, bool bom = true}) => [
      if (bom) ...(bigEndian ? [0xfe, 0xff] : [0xff, 0xfe]),
      for (final c in s.codeUnits)
        ...(bigEndian ? [c >> 8, c & 0xff] : [c & 0xff, c >> 8]),
    ];

/// An ID3v2 tag of [version] (3 or 4) with [flags], an optional extended
/// header and [padding] zero bytes after the frames
Uint8List id3(List<int> frames,
    {int version = 3,
    int flags = 0,
    List<int> extendedHeader = const [],
    int padding = 0}) {
  final body = [...extendedHeader, ...frames, ...List.filled(padding, 0)];
  return Uint8List.fromList([
    ...'ID3'.codeUnits, version, 0, flags, //
    ...synchsafe(body.length),
    ...body,
  ]);
}

List<int> uint32be(int n) =>
    [(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];
List<int> uint32le(int n) =>
    [n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff];

/// An MP4 atom
List<int> atom(String type, List<int> data) =>
    [...uint32be(8 + data.length), ...type.codeUnits, ...data];

/// An iTunes freeform (`----`) item, as taggers write ReplayGain into M4A
List<int> freeform(String name, String value) => atom('----', [
      ...atom('mean', [0, 0, 0, 0, ...'com.apple.iTunes'.codeUnits]),
      ...atom('name', [0, 0, 0, 0, ...name.codeUnits]),
      ...atom('data', [0, 0, 0, 1, 0, 0, 0, 0, ...value.codeUnits]),
    ]);

/// The start of an M4A file with [items] in moov/udta/meta/ilst, where
/// taggers put them ('meta' is a full box: version and flags first)
Uint8List m4a(List<int> items) => Uint8List.fromList([
      ...atom('ftyp', [...'M4A '.codeUnits, 0, 0, 2, 0, ...'isom'.codeUnits]),
      ...atom('moov', [
        ...atom('mvhd', List.filled(100, 0)),
        ...atom('udta', [
          ...atom('meta', [
            0, 0, 0, 0, //
            ...atom('hdlr', List.filled(25, 0)),
            ...atom('ilst', items),
          ]),
        ]),
      ]),
      ...atom('mdat', List.filled(64, 0xff)),
    ]);

/// An APEv2 tag (header, items, footer), as written in front of the audio
/// or at the end of the file
Uint8List apeTag(Map<String, String> items) {
  final itemBytes = [
    for (final MapEntry(:key, :value) in items.entries) ...[
      ...uint32le(value.length), ...uint32le(0), //
      ...key.codeUnits, 0, ...value.codeUnits,
    ],
  ];
  List<int> headerOrFooter(int flags) => [
        ...'APETAGEX'.codeUnits, ...uint32le(2000), //
        ...uint32le(itemBytes.length + 32), ...uint32le(items.length),
        ...uint32le(flags), ...List.filled(8, 0),
      ];
  return Uint8List.fromList([
    ...headerOrFooter(0xa0000000),
    ...itemBytes,
    ...headerOrFooter(0x80000000),
  ]);
}

/// The start of an Ogg Vorbis file: identification and comment headers in
/// Ogg pages (the comment header's page checksum isn't checked)
Uint8List oggVorbis(List<String> comments) {
  final vendor = 'Xiph.Org libVorbis I 20200704'.codeUnits;
  final packet = [
    3, ...'vorbis'.codeUnits, //
    ...uint32le(vendor.length), ...vendor,
    ...uint32le(comments.length),
    for (final c in comments) ...[...uint32le(c.length), ...c.codeUnits],
    1,
  ];
  List<int> page(int sequence, List<int> data) => [
        ...'OggS'.codeUnits, 0, sequence == 0 ? 2 : 0, ...List.filled(8, 0),
        ...uint32le(1), ...uint32le(sequence), ...uint32le(0),
        // One segment per 255 bytes
        (data.length + 254) ~/ 255,
        for (var left = data.length; left > 0; left -= 255) math.min(left, 255),
        ...data,
      ];
  return Uint8List.fromList([
    ...page(0, [1, ...'vorbis'.codeUnits, ...List.filled(23, 0)]),
    ...page(1, packet),
  ]);
}

double dbToLinear(double db) => math.pow(10.0, db / 20.0).toDouble();

void main() {
  group('Real-world MP3 headers (mind.in.a.box)', () {
    test('Broken Legacies - 01 Evasion', () {
      final data = ReplayGainReader.parseBytes(
          loadFixture('mindinabox_broken_legacies_01_evasion'));
      expect(data.trackGain, -6.29);
      expect(data.trackPeak, 1.0);
      expect(data.albumGain, -10.06);
      expect(data.albumPeak, 1.0);
    });

    test('Broken Legacies - 05 Ockhams Razor', () {
      final data = ReplayGainReader.parseBytes(
          loadFixture('mindinabox_broken_legacies_05_ockhams_razor'));
      expect(data.trackGain, -6.74);
      expect(data.trackPeak, 0.993683);
      expect(data.albumGain, -10.06);
      expect(data.albumPeak, 1.0);
    });

    test("R.E.T.R.O. - 10 We Can't Go Back To The Past", () {
      final data = ReplayGainReader.parseBytes(
          loadFixture('mindinabox_retro_10_we_cant_go_back'));
      expect(data.trackGain, -10.31);
      expect(data.trackPeak, 0.962524);
      expect(data.albumGain, -9.35);
      expect(data.albumPeak, 1.0);
    });

    test('reads the same values from a cached file on disk', () async {
      final file = await writeTempFile(
          loadFixture('mindinabox_broken_legacies_01_evasion'), 'evasion.mp3');

      final data = await ReplayGainReader.readFromFile(file);
      expect(data.trackGain, -6.29);
      expect(data.albumGain, -10.06);
    });
  });

  group('Real-world M4A headers', () {
    test('EMF - Travelling Not Running (iTunes freeform atoms)', () {
      final data = ReplayGainReader.parseBytes(
          loadFixture('emf_travelling_not_running', ext: 'm4a'));
      expect(data.trackGain, -8.54);
      expect(data.trackPeak, 1.0);
      expect(data.albumGain, -10.88);
      expect(data.albumPeak, 1.0);
    });
  });

  group('Metadata larger than the initial 256KB read', () {
    test('MP3 whose cover art pushes ReplayGain frames past 256KB', () async {
      final bytes = loadFixture('thebrowning_not_alone_evolved_large_cover');
      expect(bytes.length, greaterThan(256 * 1024));

      // The first 256KB alone don't contain the ReplayGain frames
      final truncated = ReplayGainReader.parseBytes(
          Uint8List.sublistView(bytes, 0, 256 * 1024));
      expect(truncated.hasAnyData, isFalse);

      final file = await writeTempFile(bytes, 'not_alone.mp3');
      final data = await ReplayGainReader.readFromFile(file);
      expect(data.trackGain, -10.44);
      expect(data.trackPeak, 1.0);
      expect(data.albumGain, -10.41);
      expect(data.albumPeak, 1.0);
    });

    test('M4A whose moov atom ends past 256KB', () async {
      final bytes =
          loadFixture('dreamtheater_octavarium_large_moov', ext: 'm4a');
      expect(bytes.length, greaterThan(256 * 1024));

      final file = await writeTempFile(bytes, 'octavarium.m4a');
      final data = await ReplayGainReader.readFromFile(file);
      expect(data.trackGain, -8.35);
      expect(data.trackPeak, 1.0);
      expect(data.albumGain, -9.47);
      expect(data.albumPeak, 1.0);
    });

    test('requiredHeaderSize covers the full ID3v2 tag', () {
      final bytes = loadFixture('thebrowning_not_alone_evolved_large_cover');
      final head = Uint8List.sublistView(bytes, 0, 256 * 1024);
      expect(ReplayGainReader.requiredHeaderSize(head), 327661);
    });

    test('requiredHeaderSize covers the full MP4 moov atom', () {
      final bytes =
          loadFixture('dreamtheater_octavarium_large_moov', ext: 'm4a');
      final head = Uint8List.sublistView(bytes, 0, 256 * 1024);
      expect(ReplayGainReader.requiredHeaderSize(head), 399069);
    });

    test('FLAC whose cover art pushes the Vorbis comment past 256KB', () async {
      final bytes = flacWithCover(400 * 1024, 'REPLAYGAIN_TRACK_GAIN=-4.20 dB');
      final file = await writeTempFile(bytes, 'cover.flac');
      final data = await ReplayGainReader.readFromFile(file);
      expect(data.trackGain, -4.20);
    });

    test('requiredHeaderSize walks the FLAC blocks to the Vorbis comment', () {
      final bytes = flacWithCover(400 * 1024, 'REPLAYGAIN_TRACK_GAIN=-4.20 dB');
      const pictureEnd = 4 + 38 + 4 + 400 * 1024;
      // The PICTURE block's end, plus the next block header
      expect(
          ReplayGainReader.requiredHeaderSize(
              Uint8List.sublistView(bytes, 0, 256 * 1024)),
          pictureEnd + 4);
      expect(
          ReplayGainReader.requiredHeaderSize(
              Uint8List.sublistView(bytes, 0, pictureEnd + 4)),
          pictureEnd + 4 + 'REPLAYGAIN_TRACK_GAIN=-4.20 dB'.length);
    });

    test('requiredHeaderSize leaves small tags alone', () {
      final bytes = loadFixture('mindinabox_broken_legacies_01_evasion');
      expect(ReplayGainReader.requiredHeaderSize(bytes), bytes.length);
    });
  });

  group('ID3v2 TXXX frames', () {
    test('parses gains with an explicit plus sign', () {
      final data = ReplayGainReader.parseBytes(id3v23([
        ...txxxFrame('REPLAYGAIN_TRACK_GAIN', '+3.10 dB'),
        ...txxxFrame('REPLAYGAIN_TRACK_PEAK', '0.95'),
      ]));
      expect(data.trackGain, 3.10);
      expect(data.trackPeak, 0.95);
    });

    test('matches lowercase descriptions', () {
      final data = ReplayGainReader.parseBytes(id3v23([
        ...txxxFrame('replaygain_track_gain', '-7.10 dB'),
      ]));
      expect(data.trackGain, -7.10);
    });
  });

  group('Vorbis comments (FLAC/OGG)', () {
    test('parses negative gains', () {
      final data = ReplayGainReader.parseBytes(ascii(
          'fLaC....REPLAYGAIN_TRACK_GAIN=-7.03 dB\x00REPLAYGAIN_ALBUM_GAIN=-8.20 dB'));
      expect(data.trackGain, -7.03);
      expect(data.albumGain, -8.20);
    });

    test('parses gains with an explicit plus sign', () {
      final data = ReplayGainReader.parseBytes(ascii(
          'fLaC....REPLAYGAIN_TRACK_GAIN=+2.50 dB\x00REPLAYGAIN_TRACK_PEAK=0.9\x00'
          'REPLAYGAIN_ALBUM_GAIN=+1.25 dB'));
      expect(data.trackGain, 2.50);
      expect(data.trackPeak, 0.9);
      expect(data.albumGain, 1.25);
    });
  });

  group('R128 gains (Opus)', () {
    test('converts Q7.8 values relative to -23 LUFS into ReplayGain dB', () {
      // -2304 / 256 = -9 dB at -23 LUFS -> -4 dB at the -18 LUFS RG reference
      final data = ReplayGainReader.parseBytes(ascii(
          'OggS....OpusTags....R128_TRACK_GAIN=-2304\x00R128_ALBUM_GAIN=512'));
      expect(data.trackGain, -4.0);
      expect(data.albumGain, 7.0);
    });

    test('prefers REPLAYGAIN_* tags over R128 when both are present', () {
      final data = ReplayGainReader.parseBytes(ascii(
          'OggS....OpusTags....R128_TRACK_GAIN=-2304\x00REPLAYGAIN_TRACK_GAIN=-3.50 dB'));
      expect(data.trackGain, -3.50);
    });
  });

  group('No ReplayGain metadata', () {
    test('does not guess a gain from unrelated "dB" text', () {
      final data = ReplayGainReader.parseBytes(
          ascii('fLaC....COMMENT=Mastered at -1 dB headroom, -14 LUFS'));
      expect(data.hasAnyData, isFalse);
    });

    test('returns no data for an empty tag', () {
      final data = ReplayGainReader.parseBytes(id3v23([]));
      expect(data.hasAnyData, isFalse);
    });
  });

  group('ID3v2 tag layouts', () {
    List<int> allFour({bool v24 = false}) => [
          for (final (key, value) in [
            ('REPLAYGAIN_TRACK_GAIN', '-6.48 dB'),
            ('REPLAYGAIN_TRACK_PEAK', '0.988525'),
            ('REPLAYGAIN_ALBUM_GAIN', '-7.25 dB'),
            ('REPLAYGAIN_ALBUM_PEAK', '1.000000'),
          ])
            ...rawTxxxFrame([0, ...key.codeUnits, 0, ...value.codeUnits],
                v24: v24),
        ];

    void expectAllFour(ReplayGainData data) {
      expect(data.trackGain, -6.48);
      expect(data.trackPeak, 0.988525);
      expect(data.albumGain, -7.25);
      expect(data.albumPeak, 1.0);
    }

    // A frame of 200 bytes: its size reads differently as a plain and as a
    // synchsafe integer, so the next frame is only found with the right one
    final comment = [0, ...'COMMENT'.codeUnits, 0, ...List.filled(191, 0x61)];

    test('ID3v2.3 frames have plain sizes', () {
      expectAllFour(ReplayGainReader.parseBytes(
          id3([...rawTxxxFrame(comment), ...allFour()])));
    });

    test('ID3v2.4 frames have synchsafe sizes', () {
      expectAllFour(ReplayGainReader.parseBytes(id3(
          [...rawTxxxFrame(comment, v24: true), ...allFour(v24: true)],
          version: 4)));
    });

    test('stops at the padding after the last frame', () {
      final data = ReplayGainReader.parseBytes(id3(allFour(), padding: 2048));
      expectAllFour(data);
    });

    test('skips an ID3v2.3 extended header', () {
      // Size (not counting itself), flags, padding size
      final extended = [...uint32be(6), 0, 0, ...uint32be(0)];
      expectAllFour(ReplayGainReader.parseBytes(
          id3(allFour(), flags: 0x40, extendedHeader: extended)));
    });

    test('skips an ID3v2.4 extended header', () {
      // Synchsafe size (counting itself), one flag byte, no flags set
      final extended = [...synchsafe(6), 1, 0];
      expectAllFour(ReplayGainReader.parseBytes(id3(allFour(v24: true),
          version: 4, flags: 0x40, extendedHeader: extended)));
    });

    test('reads the frames that arrived of a tag cut short', () {
      final tag = id3([...allFour(), ...rawTxxxFrame(comment)]);
      final data = ReplayGainReader.parseBytes(
          Uint8List.sublistView(tag, 0, tag.length - 50));
      expectAllFour(data);
    });

    test('ignores TXXX frames of other tags and values that are no number', () {
      final data = ReplayGainReader.parseBytes(id3([
        ...txxxFrame('MusicBrainz Album Id', '-1234'),
        ...txxxFrame('REPLAYGAIN_TRACK_GAIN', 'n/a dB'),
        ...txxxFrame('REPLAYGAIN_ALBUM_GAIN', '-3.00 dB'),
      ]));
      expect(data.trackGain, isNull);
      expect(data.albumGain, -3.0);
    });

    test('reads a Vorbis comment after an ID3v2 tag in front of FLAC', () {
      final data = ReplayGainReader.parseBytes(Uint8List.fromList([
        ...id3(txxxFrame('ENCODER', 'x')),
        ...flacWithCover(16, 'REPLAYGAIN_TRACK_GAIN=-5.10 dB'),
      ]));
      expect(data.trackGain, -5.10);
    });
  });

  group('ID3v2 TXXX text encodings', () {
    ReplayGainData parse(int encoding, List<int> description, List<int> value,
            {int version = 3}) =>
        ReplayGainReader.parseBytes(id3([
          ...rawTxxxFrame([encoding, ...description, ...value],
              v24: version == 4)
        ], version: version));

    test('UTF-16 little-endian with BOM', () {
      final data = parse(
          1, [...utf16('REPLAYGAIN_TRACK_GAIN'), 0, 0], utf16('-4.75 dB'));
      expect(data.trackGain, -4.75);
    });

    test('UTF-16 big-endian with BOM', () {
      final data = parse(
          1,
          [...utf16('REPLAYGAIN_ALBUM_GAIN', bigEndian: true), 0, 0],
          utf16('+1.50 dB', bigEndian: true));
      expect(data.albumGain, 1.50);
    });

    test('UTF-16 value without a BOM of its own', () {
      final data = parse(1, [...utf16('REPLAYGAIN_TRACK_PEAK'), 0, 0],
          utf16('0.891', bom: false));
      expect(data.trackPeak, 0.891);
    });

    test('UTF-16 big-endian without BOM (ID3v2.4 encoding 2)', () {
      final data = parse(
          2,
          [
            ...utf16('REPLAYGAIN_TRACK_GAIN', bigEndian: true, bom: false),
            0,
            0
          ],
          utf16('-2.25 dB', bigEndian: true, bom: false),
          version: 4);
      expect(data.trackGain, -2.25);
    });

    test('UTF-8 (ID3v2.4 encoding 3)', () {
      final data = parse(
          3, [...'REPLAYGAIN_TRACK_GAIN'.codeUnits, 0], '-8.10 dB'.codeUnits,
          version: 4);
      expect(data.trackGain, -8.10);
    });
  });

  group('APE tags', () {
    test('reads gains and peaks', () {
      final data = ReplayGainReader.parseBytes(apeTag({
        'Title': 'Something',
        'REPLAYGAIN_TRACK_GAIN': '-9.12 dB',
        'REPLAYGAIN_TRACK_PEAK': '0.977203',
        'REPLAYGAIN_ALBUM_GAIN': '+0.50 dB',
        'REPLAYGAIN_ALBUM_PEAK': '1.012000',
      }));
      expect(data.trackGain, -9.12);
      expect(data.trackPeak, 0.977203);
      expect(data.albumGain, 0.50);
      expect(data.albumPeak, 1.012);
    });

    test('matches keys in any case', () {
      final data = ReplayGainReader.parseBytes(
          apeTag({'replaygain_track_gain': '-1.00 dB'}));
      expect(data.trackGain, -1.0);
    });
  });

  group('MP4 freeform atoms', () {
    test('reads all four values from moov/udta/meta/ilst', () {
      final data = ReplayGainReader.parseBytes(m4a([
        ...atom('©nam', atom('data', [0, 0, 0, 1, 0, 0, 0, 0, 0x41])),
        ...freeform('replaygain_track_gain', '-7.03 dB'),
        ...freeform('replaygain_track_peak', '0.954132'),
        ...freeform('replaygain_album_gain', '-8.20 dB'),
        ...freeform('replaygain_album_peak', '0.999969'),
      ]));
      expect(data.trackGain, -7.03);
      expect(data.trackPeak, 0.954132);
      expect(data.albumGain, -8.20);
      expect(data.albumPeak, 0.999969);
    });

    test('reads positive gains and uppercase names', () {
      final data = ReplayGainReader.parseBytes(m4a([
        ...freeform('REPLAYGAIN_TRACK_GAIN', '+2.40 dB'),
      ]));
      expect(data.trackGain, 2.40);
    });

    test('returns no data for an M4A without ReplayGain', () {
      final data = ReplayGainReader.parseBytes(m4a([
        ...atom('©nam', atom('data', [0, 0, 0, 1, 0, 0, 0, 0, 0x41])),
      ]));
      expect(data.hasAnyData, isFalse);
    });
  });

  group('Ogg Vorbis', () {
    test('reads lowercase comment keys and peaks', () {
      final data = ReplayGainReader.parseBytes(oggVorbis([
        'TITLE=Something',
        'replaygain_track_gain=-6.10 dB',
        'replaygain_track_peak=0.912354',
        'replaygain_album_gain=-6.90 dB',
        'replaygain_album_peak=0.998901',
      ]));
      expect(data.trackGain, -6.10);
      expect(data.trackPeak, 0.912354);
      expect(data.albumGain, -6.90);
      expect(data.albumPeak, 0.998901);
    });
  });

  group('Malformed input', () {
    final fixtures = [
      loadFixture('mindinabox_broken_legacies_01_evasion'),
      loadFixture('emf_travelling_not_running', ext: 'm4a'),
      flacWithCover(1024, 'REPLAYGAIN_TRACK_GAIN=-4.20 dB'),
      oggVorbis(['REPLAYGAIN_TRACK_GAIN=-1.00 dB']),
      apeTag({'REPLAYGAIN_TRACK_GAIN': '-1.00 dB'}),
      id3(rawTxxxFrame(
          [1, ...utf16('REPLAYGAIN_TRACK_GAIN'), 0, 0, ...utf16('-1 dB')])),
    ];

    test('files cut off anywhere never throw', () {
      for (final bytes in fixtures) {
        final step = math.max(1, bytes.length ~/ 400);
        for (var end = 0; end <= bytes.length; end += step) {
          final head = Uint8List.sublistView(bytes, 0, end);
          expect(() => ReplayGainReader.parseBytes(head), returnsNormally,
              reason: 'cut at $end of ${bytes.length}');
          expect(
              () => ReplayGainReader.requiredHeaderSize(head), returnsNormally,
              reason: 'cut at $end of ${bytes.length}');
        }
      }
    });

    test('corrupted bytes never throw', () {
      final random = math.Random(42);
      for (final original in fixtures) {
        for (var round = 0; round < 50; round++) {
          final bytes = Uint8List.fromList(original);
          // Keeps the magic bytes, so the format's parser runs
          for (var i = 0; i < 20; i++) {
            final at = 8 + random.nextInt(math.max(1, bytes.length - 8));
            if (at < bytes.length) bytes[at] = random.nextInt(256);
          }
          expect(() => ReplayGainReader.parseBytes(bytes), returnsNormally);
          final required = ReplayGainReader.requiredHeaderSize(bytes);
          expect(required, inInclusiveRange(bytes.length, 16 * 1024 * 1024));
        }
      }
    });

    test('headers with sizes beyond the data never throw', () {
      for (final bytes in [
        // ID3v2 tag and frame claiming more than there is
        Uint8List.fromList([
          ...'ID3'.codeUnits,
          4,
          0,
          0,
          0x7f,
          0x7f,
          0x7f,
          0x7f,
          ...'TXXX'.codeUnits,
          0x7f,
          0x7f,
          0x7f,
          0x7f,
          0,
          0,
          0
        ]),
        // MP4 atoms of size 0, 1 (64-bit size) and too large
        Uint8List.fromList(
            [...atom('ftyp', []), ...uint32be(0), ...'moov'.codeUnits]),
        Uint8List.fromList([
          ...atom('ftyp', []),
          ...uint32be(1),
          ...'moov'.codeUnits,
          ...List.filled(8, 0xff)
        ]),
        Uint8List.fromList([
          ...atom('ftyp', []),
          ...uint32be(0xffffffff),
          ...'moov'.codeUnits
        ]),
        // FLAC block longer than the data
        Uint8List.fromList([...'fLaC'.codeUnits, 0x84, 0xff, 0xff, 0xff]),
        // APE tag header only
        Uint8List.fromList('APETAGEX'.codeUnits),
      ]) {
        expect(ReplayGainReader.parseBytes(bytes).hasAnyData, isFalse);
        expect(
            () => ReplayGainReader.requiredHeaderSize(bytes), returnsNormally);
      }
    });
  });

  group('Volume from real-world values', () {
    late SettingsService settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = SettingsService();
      await settings.initialize();
    });

    test('track and album mode use the parsed gains', () async {
      final data = ReplayGainReader.parseBytes(
          loadFixture('mindinabox_broken_legacies_05_ockhams_razor'));

      await settings.setReplayGainMode(ReplayGainMode.track);
      expect(
        settings.calculateVolumeAdjustment(
          trackGain: data.trackGain,
          albumGain: data.albumGain,
          trackPeak: data.trackPeak,
          albumPeak: data.albumPeak,
        ),
        closeTo(dbToLinear(-6.74), 1e-9),
      );

      await settings.setReplayGainMode(ReplayGainMode.album);
      expect(
        settings.calculateVolumeAdjustment(
          trackGain: data.trackGain,
          albumGain: data.albumGain,
          trackPeak: data.trackPeak,
          albumPeak: data.albumPeak,
        ),
        closeTo(dbToLinear(-10.06), 1e-9),
      );
    });

    test('quiet tracks are raised above unity, up to their peak', () async {
      await settings.setReplayGainMode(ReplayGainMode.track);

      expect(
          settings.calculateVolumeAdjustment(trackGain: 6.0, trackPeak: 0.25),
          closeTo(dbToLinear(6.0), 1e-9));
      // +12 dB would push a 0.5 peak past full scale
      expect(
          settings.calculateVolumeAdjustment(trackGain: 12.0, trackPeak: 0.5),
          closeTo(2.0, 1e-9));
    });

    test('R128-only Opus tags produce an audible volume', () async {
      final data = ReplayGainReader.parseBytes(
          ascii('OggS....OpusTags....R128_TRACK_GAIN=-2304'));

      await settings.setReplayGainMode(ReplayGainMode.track);
      expect(
        settings.calculateVolumeAdjustment(trackGain: data.trackGain),
        closeTo(dbToLinear(-4.0), 1e-9),
      );
    });
  });

  group('Reading from a URL', () {
    Future<HttpServer> serve(Future<void> Function(HttpRequest) handler) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen(handler);
      return server;
    }

    String urlOf(HttpServer server) => 'http://127.0.0.1:${server.port}/stream';

    late http.Client client;
    setUp(() => client = http.Client());
    tearDown(() => client.close());

    test('reads the tags the server returns', () async {
      final server = await serve((request) async {
        request.response
            .add(id3v23(txxxFrame('REPLAYGAIN_TRACK_GAIN', '-6.5 dB')));
        await request.response.close();
      });

      final data =
          await ReplayGainReader.readFromUrl(urlOf(server), client: client);
      expect(data.trackGain, -6.5);
    });

    test('fetches the rest of a tag larger than the first read', () async {
      final bytes = loadFixture('thebrowning_not_alone_evolved_large_cover');
      final ranges = <String>[];
      final server = await serve((request) async {
        final range = request.headers.value('range')!;
        ranges.add(range);
        final [start, end] =
            range.substring('bytes='.length).split('-').map(int.parse).toList();
        request.response
          ..statusCode = HttpStatus.partialContent
          ..add(Uint8List.sublistView(
              bytes, start, math.min(end + 1, bytes.length)));
        await request.response.close();
      });

      final data =
          await ReplayGainReader.readFromUrl(urlOf(server), client: client);
      expect(data.trackGain, -10.44);
      expect(ranges, ['bytes=0-262143', 'bytes=262144-327660']);
    });

    test('reads a large tag on from a response that ignores the range',
        () async {
      final bytes = loadFixture('thebrowning_not_alone_evolved_large_cover');
      var requests = 0;
      final server = await serve((request) async {
        requests++;
        request.response.add(bytes);
        await request.response.close();
      });

      final data =
          await ReplayGainReader.readFromUrl(urlOf(server), client: client);
      expect(data.trackGain, -10.44);
      expect(data.albumGain, -10.41);
      expect(requests, 1);
    });

    test('fetches FLAC blocks past the first read', () async {
      final bytes = flacWithCover(400 * 1024, 'REPLAYGAIN_TRACK_GAIN=-4.20 dB');
      final server = await serve((request) async {
        final range = request.headers.value('range')!;
        final [start, end] =
            range.substring('bytes='.length).split('-').map(int.parse).toList();
        request.response
          ..statusCode = HttpStatus.partialContent
          ..add(Uint8List.sublistView(
              bytes, start, math.min(end + 1, bytes.length)));
        await request.response.close();
      });

      final data =
          await ReplayGainReader.readFromUrl(urlOf(server), client: client);
      expect(data.trackGain, -4.20);
    });

    test('stops reading when the server ignores the range', () async {
      const chunk = 64 * 1024;
      const fileSize = 64 * 1024 * 1024;
      var sent = 0;
      final done = Completer<void>();
      // A raw socket: an HttpServer's response drops writes once the client
      // is gone, so it would seem to send everything
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((socket) async {
        socket.listen((_) {}, onError: (_) {});
        // The whole file, as for a transcoded stream
        final tag = id3v23(txxxFrame('REPLAYGAIN_TRACK_GAIN', '-6.5 dB'));
        try {
          socket
            ..add('HTTP/1.1 200 OK\r\n'
                    'Content-Length: ${tag.length + fileSize}\r\n\r\n'
                .codeUnits)
            ..add(tag);
          while (sent < fileSize) {
            socket.add(Uint8List(chunk));
            await socket.flush();
            sent += chunk;
          }
          await socket.close();
        } catch (_) {
          // The client closed the connection
        }
        done.complete();
      });

      final data = await ReplayGainReader.readFromUrl(
          'http://127.0.0.1:${server.port}/stream',
          client: client);
      expect(data.trackGain, -6.5);
      await done.future.timeout(const Duration(seconds: 5));
      // Socket buffers take a few MB at most
      expect(sent, lessThan(fileSize ~/ 4));
    });

    group('with a fallback URL', () {
      /// Serves the tags at /stream, and answers /download with [download]
      Future<(String, String, List<String>)> serveBoth(
          Future<void> Function(HttpResponse) download) async {
        final paths = <String>[];
        final server = await serve((request) async {
          paths.add(request.uri.path);
          if (request.uri.path == '/download') {
            await download(request.response);
          } else {
            request.response
                .add(id3v23(txxxFrame('REPLAYGAIN_TRACK_GAIN', '-6.5 dB')));
          }
          await request.response.close();
        });
        final base = 'http://127.0.0.1:${server.port}';
        return ('$base/download', '$base/stream', paths);
      }

      test('reads only the first URL when it serves the file', () async {
        final (download, stream, paths) = await serveBoth((response) async {
          response.headers.contentType = ContentType('audio', 'flac');
          response.add(flacWithCover(16, 'REPLAYGAIN_TRACK_GAIN=-2.00 dB'));
        });

        final data = await ReplayGainReader.readFromUrl(download,
            fallbackUrl: stream, client: client);
        expect(data.trackGain, -2.0);
        expect(paths, ['/download']);
      });

      test('does not read the fallback for a file without tags', () async {
        final (download, stream, paths) = await serveBoth((response) async {
          response.headers.contentType = ContentType('audio', 'mpeg');
          response.add(List.filled(1024, 0xff));
        });

        final data = await ReplayGainReader.readFromUrl(download,
            fallbackUrl: stream, client: client);
        expect(data.hasAnyData, isFalse);
        expect(paths, ['/download']);
      });

      test('reads the fallback for a Subsonic error response', () async {
        // Navidrome with downloads disabled: an error with HTTP 200
        final (download, stream, paths) = await serveBoth((response) async {
          response.headers.contentType = ContentType('application', 'xml');
          response.write('<subsonic-response status="failed">'
              '<error code="50" message="downloads are disabled"/>'
              '</subsonic-response>');
        });

        final data = await ReplayGainReader.readFromUrl(download,
            fallbackUrl: stream, client: client);
        expect(data.trackGain, -6.5);
        expect(paths, ['/download', '/stream']);
      });

      test('reads the fallback for an error status', () async {
        final (download, stream, paths) = await serveBoth((response) async {
          response.statusCode = HttpStatus.forbidden;
        });

        final data = await ReplayGainReader.readFromUrl(download,
            fallbackUrl: stream, client: client);
        expect(data.trackGain, -6.5);
        expect(paths, ['/download', '/stream']);
      });

      test('gives up on both within the timeout', () async {
        final paths = <String>[];
        // The first URL never answers
        final server = await serve((request) async {
          paths.add(request.uri.path);
          if (request.uri.path == '/download') {
            await Completer<void>().future;
          }
          request.response
              .add(id3v23(txxxFrame('REPLAYGAIN_TRACK_GAIN', '-6.5 dB')));
          await request.response.close();
        });
        final base = 'http://127.0.0.1:${server.port}';

        final data = await ReplayGainReader.readFromUrl('$base/download',
            fallbackUrl: '$base/stream',
            client: client,
            timeout: const Duration(milliseconds: 200));
        expect(data.hasAnyData, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(paths, ['/download']);
      });
    });

    test('gives up with no data when the server does not answer', () async {
      // Accepts the request but never responds, like a stalled connection
      final server = await serve((_) => Completer<void>().future);

      final stopwatch = Stopwatch()..start();
      final data = await ReplayGainReader.readFromUrl(urlOf(server),
          client: client, timeout: const Duration(milliseconds: 200));
      expect(data.hasAnyData, isFalse);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });
}
