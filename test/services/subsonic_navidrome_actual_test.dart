import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:xml/xml.dart';

void main() {
  group('Subsonic Navidrome Real Server Response', () {
    test(
        'parses ReplayGain from actual Navidrome album response (The Facets of Propaganda)',
        () {
      // This is a snippet of the actual XML response from music.raven.ch
      // for the album "Imperium Delirium" by Shadow of Intent
      final xml = '''
        <song 
          xmlns="http://subsonic.org/restapi"
          id="BGA7cMSVww9FOPoQy3rENz" 
          parent="1Twsp9j5Uofd3vRWoyC547" 
          isDir="false" 
          title="The Facets of Propaganda" 
          album="Imperium Delirium" 
          artist="Shadow of Intent" 
          track="6" 
          year="2025" 
          genre="Deathcore" 
          coverArt="mf-BGA7cMSVww9FOPoQy3rENz_69a14c23" 
          size="12979081" 
          contentType="audio/mpeg" 
          suffix="mp3" 
          duration="319" 
          bitRate="320" 
          path="Shadow of Intent/Imperium Delirium/01-06 - The Facets of Propaganda.mp3" 
          playCount="2" 
          discNumber="1" 
          created="2026-02-27T06:28:34.732068459Z" 
          albumId="1Twsp9j5Uofd3vRWoyC547" 
          artistId="5DWvaJehuZJQTp2Fx7UCUP" 
          type="music" 
          played="2026-02-27T15:31:46.192Z" 
          comment="Visit https://shadowofintent7.bandcamp.com" 
          sortName="the facets of propaganda" 
          mediaType="song" 
          musicBrainzId="e4db1b6a-4417-40b6-b0c8-b0290227f05e" 
          channelCount="2" 
          samplingRate="44100" 
          displayArtist="Shadow of Intent" 
          displayAlbumArtist="Shadow of Intent">
          <isrc>FR59R2591368</isrc>
          <genres name="Deathcore"></genres>
          <replayGain trackGain="-12.68" albumGain="-13.2" trackPeak="1" albumPeak="1"></replayGain>
          <artists id="5DWvaJehuZJQTp2Fx7UCUP" name="Shadow of Intent"></artists>
          <albumArtists id="5DWvaJehuZJQTp2Fx7UCUP" name="Shadow of Intent"></albumArtists>
        </song>
      ''';

      final doc = XmlDocument.parse(xml);
      final songElement = doc.rootElement;
      final song = Song.fromXml(songElement);

      // Basic song info
      expect(song.id, 'BGA7cMSVww9FOPoQy3rENz');
      expect(song.title, 'The Facets of Propaganda');
      expect(song.album, 'Imperium Delirium');
      expect(song.artist, 'Shadow of Intent');
      expect(song.track, 6);
      expect(song.duration, 319);

      // The CRITICAL assertions - ReplayGain MUST be parsed!
      expect(song.replayGainTrackGain, -12.68,
          reason: 'ReplayGain trackGain should be parsed from nested element');
      expect(song.replayGainAlbumGain, -13.2,
          reason: 'ReplayGain albumGain should be parsed from nested element');
      expect(song.replayGainTrackPeak, 1.0,
          reason: 'ReplayGain trackPeak should be parsed from nested element');
      expect(song.replayGainAlbumPeak, 1.0,
          reason: 'ReplayGain albumPeak should be parsed from nested element');
    });

    test('parses full album response with multiple songs', () {
      // This tests parsing an album response that contains multiple songs
      // Simplified version with just 2 songs for testing
      final xml = '''
        <subsonic-response xmlns="http://subsonic.org/restapi" status="ok" version="1.16.1" type="navidrome" serverVersion="0.60.3">
          <album id="1Twsp9j5Uofd3vRWoyC547" name="Imperium Delirium" artist="Shadow of Intent">
            <song id="nWAX9u3zP53H1QktSxJ3Hh" title="Prepare to Die" album="Imperium Delirium" artist="Shadow of Intent" track="1" duration="241" suffix="mp3" contentType="audio/mpeg">
              <replayGain trackGain="-12.84" albumGain="-13.2" trackPeak="1" albumPeak="1"></replayGain>
            </song>
            <song id="BGA7cMSVww9FOPoQy3rENz" title="The Facets of Propaganda" album="Imperium Delirium" artist="Shadow of Intent" track="6" duration="319" suffix="mp3" contentType="audio/mpeg">
              <replayGain trackGain="-12.68" albumGain="-13.2" trackPeak="1" albumPeak="1"></replayGain>
            </song>
          </album>
        </subsonic-response>
      ''';

      final doc = XmlDocument.parse(xml);
      final albumElement = doc.findAllElements('album').first;
      final album = Album.fromXml(albumElement);

      expect(album.songs.length, 2);

      // Check first song
      final song1 = album.songs[0];
      expect(song1.title, 'Prepare to Die');
      expect(song1.replayGainTrackGain, -12.84);
      expect(song1.replayGainAlbumGain, -13.2);

      // Check second song (The Facets of Propaganda)
      final song2 = album.songs[1];
      expect(song2.title, 'The Facets of Propaganda');
      expect(song2.replayGainTrackGain, -12.68);
      expect(song2.replayGainAlbumGain, -13.2);
    });
  });
}
