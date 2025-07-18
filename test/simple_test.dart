import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/services/subsonic_api.dart';

void main() {
  group('Simple Tests', () {
    
    test('Song class should work correctly', () {
      final song = Song(
        id: '1',
        title: 'Test Song',
        artist: 'Test Artist',
        album: 'Test Album',
      );
      
      expect(song.id, equals('1'));
      expect(song.title, equals('Test Song'));
      expect(song.artist, equals('Test Artist'));
      expect(song.album, equals('Test Album'));
    });
    
    test('Album class should work correctly', () {
      final album = Album(
        id: '1',
        name: 'Test Album',
        artist: 'Test Artist',
        songCount: 10,
        songs: [],
      );
      
      expect(album.id, equals('1'));
      expect(album.name, equals('Test Album'));
      expect(album.artist, equals('Test Artist'));
      expect(album.songCount, equals(10));
      expect(album.songs, isEmpty);
    });
    
    test('Artist class should work correctly', () {
      final artist = Artist(
        id: '1',
        name: 'Test Artist',
        albumCount: 5,
      );
      
      expect(artist.id, equals('1'));
      expect(artist.name, equals('Test Artist'));
      expect(artist.albumCount, equals(5));
    });
    
    test('SearchResult class should work correctly', () {
      final searchResult = SearchResult(
        artists: [],
        albums: [],
        songs: [],
      );
      
      expect(searchResult.artists, isEmpty);
      expect(searchResult.albums, isEmpty);
      expect(searchResult.songs, isEmpty);
    });
    
    test('Song equality should work correctly', () {
      final song1 = Song(
        id: '1',
        title: 'Test Song',
        artist: 'Test Artist',
        album: 'Test Album',
      );
      
      final song2 = Song(
        id: '1',
        title: 'Test Song',
        artist: 'Test Artist',
        album: 'Test Album',
      );
      
      final song3 = Song(
        id: '2',
        title: 'Different Song',
        artist: 'Test Artist',
        album: 'Test Album',
      );
      
      expect(song1, equals(song2));
      expect(song1, isNot(equals(song3)));
    });
    
    test('Album equality should work correctly', () {
      final album1 = Album(
        id: '1',
        name: 'Test Album',
        artist: 'Test Artist',
        songCount: 10,
        songs: [],
      );
      
      final album2 = Album(
        id: '1',
        name: 'Test Album',
        artist: 'Test Artist',
        songCount: 10,
        songs: [],
      );
      
      final album3 = Album(
        id: '2',
        name: 'Different Album',
        artist: 'Test Artist',
        songCount: 5,
        songs: [],
      );
      
      expect(album1, equals(album2));
      expect(album1, isNot(equals(album3)));
    });
    
  });
}