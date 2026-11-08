import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:voidweaver/services/replaygain_reader.dart';
import 'package:voidweaver/services/replaygain_resolver.dart';
import 'package:voidweaver/services/subsonic_api.dart';

import '../test_helpers/fake_audio_cache.dart';
import '../test_helpers/mock_api.dart';
import '../test_helpers/mocks.mocks.dart';

void main() {
  late MockSubsonicApi api;
  late MockSettingsService settings;
  late FakeAudioCache cache;
  late ReplayGainResolver resolver;

  Song song({double? trackGain, double? albumGain}) => Song(
    id: 's1',
    title: 'Title',
    artist: 'Artist',
    album: 'Album',
    duration: 180,
    replayGainTrackGain: trackGain,
    replayGainAlbumGain: albumGain,
    replayGainTrackPeak: 0.9,
    replayGainAlbumPeak: 0.95,
  );

  setUp(() {
    api = newMockApi();
    settings = MockSettingsService();
    cache = FakeAudioCache();
    resolver = ReplayGainResolver(settings, cache, api);
  });

  group('gainFor', () {
    test('passes the song\'s data and the queue kind to the settings', () {
      when(
        settings.calculateVolumeAdjustment(
          trackGain: anyNamed('trackGain'),
          albumGain: anyNamed('albumGain'),
          trackPeak: anyNamed('trackPeak'),
          albumPeak: anyNamed('albumPeak'),
          fromAlbum: anyNamed('fromAlbum'),
        ),
      ).thenReturn(0.5);

      final gain = resolver.gainFor(
        song(trackGain: -6, albumGain: -5),
        fromAlbum: true,
      );

      expect(gain, 0.5);
      verify(
        settings.calculateVolumeAdjustment(
          trackGain: -6,
          albumGain: -5,
          trackPeak: 0.9,
          albumPeak: 0.95,
          fromAlbum: true,
        ),
      ).called(1);
    });
  });

  group('readMissing', () {
    test('reads nothing for a song the server sent data for', () async {
      expect(await resolver.readMissing(song(trackGain: -6)), isNull);
      expect(await resolver.readMissing(song(albumGain: -6)), isNull);

      verifyNever(api.readReplayGain(any));
    });

    test('prefers the downloaded file', () async {
      cache.cached.add('s1');
      cache.tags['s1'] = const ReplayGainData(trackGain: -8);

      final data = await resolver.readMissing(song());

      expect(data?.trackGain, -8);
      verifyNever(api.readReplayGain(any));
    });

    test(
      'reads the file on the server when the cached tag is cut off',
      () async {
        // A partly cached track whose tag runs past the cached part
        cache.cached.add('s1');
        cache.tags['s1'] = const ReplayGainData.unavailable();
        when(api.readReplayGain('s1'))
            .thenAnswer((_) async => const ReplayGainData(trackGain: -9));

        final data = await resolver.readMissing(song());

        expect(data?.trackGain, -9);
      },
    );

    test('reads the start of the file on the server otherwise', () async {
      when(api.readReplayGain('s1'))
          .thenAnswer((_) async => const ReplayGainData(trackGain: -9));

      final data = await resolver.readMissing(song());

      expect(data?.trackGain, -9);
    });

    test('returns null when the file can\'t be read', () async {
      when(api.readReplayGain('s1')).thenThrow(Exception('offline'));

      expect(await resolver.readMissing(song()), isNull);
    });

    // Starts and skips wait for the read, up to a few seconds each time
    test('does not read a file without tags again', () async {
      when(api.readReplayGain('s1'))
          .thenAnswer((_) async => const ReplayGainData());

      final first = await resolver.readMissing(song());
      final second = await resolver.readMissing(song());

      expect(first?.hasAnyData, isFalse);
      expect(second?.hasAnyData, isFalse);
      verify(api.readReplayGain('s1')).called(1);
    });

    test('reads again after the file could not be read', () async {
      var reads = 0;
      when(api.readReplayGain('s1')).thenAnswer(
        (_) async => ++reads == 1
            ? const ReplayGainData.unavailable()
            : const ReplayGainData(trackGain: -7),
      );

      await resolver.readMissing(song());
      final data = await resolver.readMissing(song());

      expect(data?.trackGain, -7);
      verify(api.readReplayGain('s1')).called(2);
    });

    test('reads again after a read that threw', () async {
      var reads = 0;
      when(api.readReplayGain('s1')).thenAnswer((_) async {
        if (++reads == 1) throw Exception('offline');
        return const ReplayGainData(trackGain: -7);
      });

      expect(await resolver.readMissing(song()), isNull);
      final data = await resolver.readMissing(song());

      expect(data?.trackGain, -7);
      verify(api.readReplayGain('s1')).called(2);
    });

    test('remembers a downloaded file without tags too', () async {
      cache.cached.add('s1');
      cache.tags['s1'] = const ReplayGainData();

      await resolver.readMissing(song());
      cache.cached.remove('s1');
      await resolver.readMissing(song());

      verifyNever(api.readReplayGain(any));
    });
  });
}
