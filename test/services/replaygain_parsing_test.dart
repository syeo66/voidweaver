import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/services/subsonic_api.dart';

void main() {
  group('ReplayGain Parsing Tests', () {
    test('should parse flat replayGain format (as toJson writes it)', () {
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

    test('should handle integer values in replayGain fields', () {
      final json = {
        'id': 'test-song-6',
        'title': 'Integer Values',
        'artist': 'Test Artist',
        'album': 'Test Album',
        'duration': 180,
        'replayGainTrackGain': -12,
        'replayGainAlbumGain': -13,
        'replayGainTrackPeak': 1,
        'replayGainAlbumPeak': 1,
      };

      final song = Song.fromJson(json);

      expect(song.replayGainTrackGain, -12.0);
      expect(song.replayGainAlbumGain, -13.0);
      expect(song.replayGainTrackPeak, 1.0);
      expect(song.replayGainAlbumPeak, 1.0);
    });

    test('reads back what toJson wrote', () {
      final song = Song(
        id: 'test-song-7',
        title: 'Round Trip',
        artist: 'Test Artist',
        album: 'Test Album',
        replayGainTrackGain: -7.25,
        replayGainAlbumGain: -8.5,
        replayGainTrackPeak: 0.97,
        replayGainAlbumPeak: 0.99,
      );

      expect(Song.fromJson(song.toJson()), song);
    });
  });
}
