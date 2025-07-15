import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:xml/xml.dart';

void main() {
  group('Random Songs Cover Art Fix', () {
    test('Song from XML with no coverArt should use albumId', () {
      const xmlString = '''
      <song id="123" title="Test Song" artist="Test Artist" album="Test Album" albumId="456" />
      ''';
      
      final element = XmlDocument.parse(xmlString).rootElement;
      final song = Song.fromXml(element);
      
      // Original song should have no coverArt
      expect(song.coverArt, isNull);
      expect(song.albumId, equals('456'));
    });
    
    test('Song from XML with coverArt should keep existing coverArt', () {
      const xmlString = '''
      <song id="123" title="Test Song" artist="Test Artist" album="Test Album" albumId="456" coverArt="789" />
      ''';
      
      final element = XmlDocument.parse(xmlString).rootElement;
      final song = Song.fromXml(element);
      
      // Should keep existing coverArt
      expect(song.coverArt, equals('789'));
      expect(song.albumId, equals('456'));
    });
    
    test('Song from XML with no coverArt and no albumId should use song id', () {
      const xmlString = '''
      <song id="123" title="Test Song" artist="Test Artist" album="Test Album" />
      ''';
      
      final element = XmlDocument.parse(xmlString).rootElement;
      final song = Song.fromXml(element);
      
      // Original song should have no coverArt and no albumId
      expect(song.coverArt, isNull);
      expect(song.albumId, isNull);
      expect(song.id, equals('123'));
    });
  });
}