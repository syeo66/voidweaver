import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:xml/xml.dart';

void main() {
  group('Subsonic ReplayGain XML Parsing', () {
    test(
        'parses nested replayGain element with namespace (OpenSubsonic/Navidrome format)',
        () {
      // This is the actual format from Navidrome (music.raven.ch)
      final xml = '''
        <song 
          xmlns="http://subsonic.org/restapi"
          id="IyHBg1hnQIUpqe826o2Nnm" 
          title="Anti-Theist" 
          album="Conqueror" 
          artist="Mechina" 
          track="4" 
          duration="227" 
          suffix="mp3"
          contentType="audio/mpeg">
          <replayGain trackGain="-12.97" albumGain="-12.37" trackPeak="1" albumPeak="1"></replayGain>
        </song>
      ''';

      final doc = XmlDocument.parse(xml);
      final songElement = doc.rootElement;
      final song = Song.fromXml(songElement);

      expect(song.id, 'IyHBg1hnQIUpqe826o2Nnm');
      expect(song.title, 'Anti-Theist');
      expect(song.album, 'Conqueror');
      expect(song.artist, 'Mechina');

      // The critical assertions - these should pass now!
      expect(song.replayGainTrackGain, -12.97);
      expect(song.replayGainAlbumGain, -12.37);
      expect(song.replayGainTrackPeak, 1.0);
      expect(song.replayGainAlbumPeak, 1.0);
    });

    test('parses nested replayGain element without namespace', () {
      final xml = '''
        <song 
          id="test123" 
          title="Test Song" 
          album="Test Album" 
          artist="Test Artist" 
          track="1" 
          duration="180" 
          suffix="mp3"
          contentType="audio/mpeg">
          <replayGain trackGain="-8.5" albumGain="-9.2" trackPeak="0.95" albumPeak="0.98"></replayGain>
        </song>
      ''';

      final doc = XmlDocument.parse(xml);
      final songElement = doc.rootElement;
      final song = Song.fromXml(songElement);

      expect(song.replayGainTrackGain, -8.5);
      expect(song.replayGainAlbumGain, -9.2);
      expect(song.replayGainTrackPeak, 0.95);
      expect(song.replayGainAlbumPeak, 0.98);
    });

    test('falls back to song element attributes when no nested element', () {
      final xml = '''
        <song 
          id="test456" 
          title="Test Song 2" 
          album="Test Album" 
          artist="Test Artist" 
          track="2" 
          duration="200" 
          suffix="mp3"
          contentType="audio/mpeg"
          replayGainTrackGain="-10.5"
          replayGainAlbumGain="-11.0">
        </song>
      ''';

      final doc = XmlDocument.parse(xml);
      final songElement = doc.rootElement;
      final song = Song.fromXml(songElement);

      expect(song.replayGainTrackGain, -10.5);
      expect(song.replayGainAlbumGain, -11.0);
    });

    test('handles missing ReplayGain data gracefully', () {
      final xml = '''
        <song 
          id="test789" 
          title="Test Song 3" 
          album="Test Album" 
          artist="Test Artist" 
          track="3" 
          duration="150" 
          suffix="mp3"
          contentType="audio/mpeg">
        </song>
      ''';

      final doc = XmlDocument.parse(xml);
      final songElement = doc.rootElement;
      final song = Song.fromXml(songElement);

      expect(song.replayGainTrackGain, isNull);
      expect(song.replayGainAlbumGain, isNull);
      expect(song.replayGainTrackPeak, isNull);
      expect(song.replayGainAlbumPeak, isNull);
    });

    test('nested element takes precedence over attributes', () {
      final xml = '''
        <song 
          id="test999" 
          title="Test Song 4" 
          album="Test Album" 
          artist="Test Artist" 
          track="4" 
          duration="220" 
          suffix="mp3"
          contentType="audio/mpeg"
          replayGainTrackGain="-5.0"
          replayGainAlbumGain="-6.0">
          <replayGain trackGain="-15.5" albumGain="-16.0" trackPeak="0.88" albumPeak="0.92"></replayGain>
        </song>
      ''';

      final doc = XmlDocument.parse(xml);
      final songElement = doc.rootElement;
      final song = Song.fromXml(songElement);

      // Should use nested element values, not attributes
      expect(song.replayGainTrackGain, -15.5);
      expect(song.replayGainAlbumGain, -16.0);
      expect(song.replayGainTrackPeak, 0.88);
      expect(song.replayGainAlbumPeak, 0.92);
    });
  });
}
