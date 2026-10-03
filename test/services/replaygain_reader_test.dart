import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
}
