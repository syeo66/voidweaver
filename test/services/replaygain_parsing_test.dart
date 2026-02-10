import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/services/subsonic_api.dart';

void main() {
  group('ReplayGain Parsing Tests', () {
    test('should parse nested replayGain format (Navidrome/OpenSubsonic)', () {
      final json = {
        'id': 'test-song-1',
        'title': 'Tartarus',
        'artist': 'Mechina',
        'album': 'Xenon',
        'albumId': 'album-1',
        'duration': 354,
        'track': 6,
        'replayGain': {
          'trackGain': -12.61,
          'albumGain': -12.97,
          'trackPeak': 1.0,
          'albumPeak': 1.0,
        },
      };

      final song = Song.fromJson(json);

      expect(song.id, 'test-song-1');
      expect(song.title, 'Tartarus');
      expect(song.replayGainTrackGain, -12.61);
      expect(song.replayGainAlbumGain, -12.97);
      expect(song.replayGainTrackPeak, 1.0);
      expect(song.replayGainAlbumPeak, 1.0);
    });

    test('should parse flat replayGain format (legacy)', () {
      final json = {
        'id': 'test-song-2',
        'title': 'Test Song',
        'artist': 'Test Artist',
        'album': 'Test Album',
        'duration': 180,
        'replayGainTrackGain': -8.5,
        'replayGainAlbumGain': -9.2,
        'replayGainTrackPeak': 0.95,
        'replayGainAlbumPeak': 0.98,
      };

      final song = Song.fromJson(json);

      expect(song.id, 'test-song-2');
      expect(song.title, 'Test Song');
      expect(song.replayGainTrackGain, -8.5);
      expect(song.replayGainAlbumGain, -9.2);
      expect(song.replayGainTrackPeak, 0.95);
      expect(song.replayGainAlbumPeak, 0.98);
    });

    test('should handle missing replayGain data gracefully', () {
      final json = {
        'id': 'test-song-3',
        'title': 'No RG Data',
        'artist': 'Test Artist',
        'album': 'Test Album',
        'duration': 120,
      };

      final song = Song.fromJson(json);

      expect(song.id, 'test-song-3');
      expect(song.title, 'No RG Data');
      expect(song.replayGainTrackGain, isNull);
      expect(song.replayGainAlbumGain, isNull);
      expect(song.replayGainTrackPeak, isNull);
      expect(song.replayGainAlbumPeak, isNull);
    });

    test('should handle partial replayGain data in nested format', () {
      final json = {
        'id': 'test-song-4',
        'title': 'Partial RG Data',
        'artist': 'Test Artist',
        'album': 'Test Album',
        'duration': 200,
        'replayGain': {
          'trackGain': -10.5,
          // albumGain missing
          'trackPeak': 0.92,
          // albumPeak missing
        },
      };

      final song = Song.fromJson(json);

      expect(song.id, 'test-song-4');
      expect(song.replayGainTrackGain, -10.5);
      expect(song.replayGainAlbumGain, isNull);
      expect(song.replayGainTrackPeak, 0.92);
      expect(song.replayGainAlbumPeak, isNull);
    });

    test('should prefer nested format over flat format when both exist', () {
      final json = {
        'id': 'test-song-5',
        'title': 'Both Formats',
        'artist': 'Test Artist',
        'album': 'Test Album',
        'duration': 150,
        'replayGain': {
          'trackGain': -11.0,
          'albumGain': -11.5,
        },
        'replayGainTrackGain': -5.0, // Should be ignored
        'replayGainAlbumGain': -5.5, // Should be ignored
      };

      final song = Song.fromJson(json);

      expect(song.replayGainTrackGain, -11.0); // Nested value, not flat value
      expect(song.replayGainAlbumGain, -11.5); // Nested value, not flat value
    });

    test('should handle integer values in replayGain fields', () {
      final json = {
        'id': 'test-song-6',
        'title': 'Integer Values',
        'artist': 'Test Artist',
        'album': 'Test Album',
        'duration': 180,
        'replayGain': {
          'trackGain': -12, // Integer instead of double
          'albumGain': -13, // Integer instead of double
          'trackPeak': 1, // Integer instead of double
          'albumPeak': 1, // Integer instead of double
        },
      };

      final song = Song.fromJson(json);

      expect(song.replayGainTrackGain, -12.0);
      expect(song.replayGainAlbumGain, -13.0);
      expect(song.replayGainTrackPeak, 1.0);
      expect(song.replayGainAlbumPeak, 1.0);
    });
  });
}
