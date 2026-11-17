import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/models/subsonic_models.dart';
import 'package:xml/xml.dart';

XmlDocument _xml(String body) => XmlDocument.parse(body);

void main() {
  final song = Song(
    id: 's1',
    title: 'Title',
    artist: 'Artist',
    album: 'Album',
    albumId: 'al1',
    coverArt: 'al-1',
    duration: 215,
    track: 3,
    contentType: 'audio/flac',
    suffix: 'flac',
    size: 31457280,
    replayGainTrackGain: -6.5,
    replayGainAlbumGain: -7.25,
    replayGainTrackPeak: 0.98,
    replayGainAlbumPeak: 1.0,
  );

  group('JSON, as the library cache stores it', () {
    test('a song comes back as it was', () {
      final copy = Song.fromJson(song.toJson());

      expect(copy, song);
      expect(copy.hashCode, song.hashCode);
    });

    test('an album with its songs comes back as it was', () {
      final album = Album(
        id: 'al1',
        name: 'Album',
        artist: 'Artist',
        artistId: 'ar1',
        coverArt: 'al-1',
        songCount: 1,
        duration: 215,
        created: DateTime.utc(2026, 11, 1, 12),
        songs: [song],
      );

      final copy = Album.fromJson(album.toJson());

      expect(copy, album);
      expect(copy.hashCode, album.hashCode);
    });

    test('an artist comes back as it was', () {
      final artist = Artist(
        id: 'ar1',
        name: 'Artist',
        coverArt: 'ar-1',
        albumCount: 4,
      );

      final copy = Artist.fromJson(artist.toJson());

      expect(copy, artist);
      expect(copy.hashCode, artist.hashCode);
    });

    test('a gain stored as a whole number is read as a double', () {
      // JSON writes -6.0 as -6 in some encoders; reading it as a double must
      // not throw, or the whole cached list is dropped
      final copy = Song.fromJson({
        ...song.toJson(),
        'replayGainTrackGain': -6,
        'replayGainTrackPeak': 1,
      });

      expect(copy.replayGainTrackGain, -6.0);
      expect(copy.replayGainTrackPeak, 1.0);
    });

    test('entries without fields get empty values, not an error', () {
      // Written by an older version, or by one that stored less
      final song = Song.fromJson(const {});
      final album = Album.fromJson(const {});
      final artist = Artist.fromJson(const {});

      expect(song.id, '');
      expect(song.title, '');
      expect(song.replayGainTrackGain, isNull);
      expect(album.name, '');
      expect(album.songs, isEmpty);
      expect(album.created, isNull);
      expect(artist.name, '');
      expect(artist.albumCount, isNull);
    });

    test('a date that can\'t be read is no date', () {
      expect(Album.fromJson({'created': 'last week'}).created, isNull);
    });
  });

  group('equality', () {
    test('differs by any field of a song', () {
      expect(song.copyWith(size: 1), isNot(song));
      expect(song.copyWith(replayGainAlbumGain: 0), isNot(song));
      expect(song.copyWith(title: 'Other'), isNot(song));
      expect(song.copyWith(), song);
    });

    test('differs by the songs of an album', () {
      final album = Album(id: 'a', name: 'n', artist: 'x', songs: [song]);

      expect(
        Album(
          id: 'a',
          name: 'n',
          artist: 'x',
          songs: [song.copyWith(id: 'o')],
        ),
        isNot(album),
      );
      expect(
        Album(id: 'a', name: 'n', artist: 'x', songs: [song, song]),
        isNot(album),
      );
      expect(Album(id: 'a', name: 'n', artist: 'x', songs: [song]), album);
    });

    test('differs by any field of an artist', () {
      final artist = Artist(id: 'a', name: 'n', albumCount: 1);

      expect(Artist(id: 'a', name: 'n', albumCount: 2), isNot(artist));
      expect(Artist(id: 'a', name: 'o', albumCount: 1), isNot(artist));
      expect(Artist(id: 'a', name: 'n', albumCount: 1), artist);
    });
  });

  group('from the server\'s XML', () {
    test('an album takes its songs and ignores numbers it can\'t read', () {
      final album = Album.fromXml(
        _xml('''
<album id="al1" name="Album" artist="Artist" songCount="many"
       duration="" created="not a date">
  <song id="s1" title="One" track="1"/>
  <song id="s2" title="Two" track="2"/>
</album>''').rootElement,
      );

      expect(album.songs.map((s) => s.id), ['s1', 's2']);
      expect(album.songCount, isNull);
      expect(album.duration, isNull);
      expect(album.created, isNull);
    });

    test('a song without a cover uses its album\'s', () {
      final parsed = Song.fromXml(
        _xml('<song id="s1" title="One" albumId="al1"/>').rootElement,
      );

      expect(parsed.coverArt, 'al1');
    });

    test('missing attributes give empty values', () {
      final parsed = Song.fromXml(_xml('<song/>').rootElement);

      expect(parsed.id, '');
      expect(parsed.title, '');
      expect(parsed.artist, '');
      expect(parsed.album, '');
      expect(parsed.size, isNull);
      expect(parsed.replayGainTrackGain, isNull);
    });
  });

  group('SearchResult', () {
    test('has the artists, albums and songs of a search', () {
      final result = SearchResult.fromXml(
        _xml('''
<subsonic-response status="ok" version="1.16.1">
  <searchResult3>
    <artist id="ar1" name="Artist" albumCount="2"/>
    <artist id="ar2" name="Other"/>
    <album id="al1" name="Album" artist="Artist"/>
    <song id="s1" title="One" artist="Artist" album="Album"/>
    <song id="s2" title="Two" artist="Artist" album="Album"/>
    <song id="s3" title="Three" artist="Artist" album="Album"/>
  </searchResult3>
</subsonic-response>'''),
      );

      expect(result.artists.map((a) => a.id), ['ar1', 'ar2']);
      expect(result.albums.map((a) => a.id), ['al1']);
      expect(result.songs.map((s) => s.id), ['s1', 's2', 's3']);
      expect(result.isEmpty, isFalse);
      expect(result.isNotEmpty, isTrue);
    });

    test('is found under the Subsonic namespace', () {
      final result = SearchResult.fromXml(
        _xml('''
<subsonic-response xmlns="http://subsonic.org/restapi" status="ok">
  <searchResult3><song id="s1" title="One"/></searchResult3>
</subsonic-response>'''),
      );

      expect(result.songs.map((s) => s.id), ['s1']);
    });

    test('is empty when nothing matched', () {
      final result = SearchResult.fromXml(
        _xml(
          '<subsonic-response status="ok"><searchResult3/></subsonic-response>',
        ),
      );

      expect(result.isEmpty, isTrue);
      expect(result.isNotEmpty, isFalse);
    });

    test('is empty when the answer has no search result', () {
      // A server or proxy that answers with something else
      final result = SearchResult.fromXml(
        _xml('<subsonic-response status="ok"><license/></subsonic-response>'),
      );

      expect(result.isEmpty, isTrue);
    });
  });
}
