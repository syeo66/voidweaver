import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/utils/sort_key.dart';

void main() {
  group('artistSortKey', () {
    const articles = ['The', 'El', 'La', 'Les'];

    test('drops a leading article, in any case', () {
      expect(artistSortKey('The Beatles', articles), 'beatles');
      expect(artistSortKey('THE CURE', articles), 'cure');
      expect(
        artistSortKey('Les Négresses Vertes', articles),
        'negresses vertes',
      );
    });

    test('keeps an article that is only part of a word or the name', () {
      expect(
        artistSortKey('Theory of a Deadman', articles),
        'theory of a deadman',
      );
      expect(artistSortKey('The', articles), 'the');
      expect(artistSortKey('The The', articles), 'the');
    });

    test('drops only the first article', () {
      expect(artistSortKey('The La Lune', articles), 'la lune');
    });

    test('keeps every article without ignored articles', () {
      expect(artistSortKey('The Beatles', const []), 'the beatles');
    });

    test('folds accents and ligatures', () {
      expect(artistSortKey('Élodie Frégé', articles), 'elodie frege');
      expect(artistSortKey('Ænima Œuvre', articles), 'aenima oeuvre');
      expect(artistSortKey('Die Ärzte', articles), 'die arzte');
      expect(artistSortKey('Straßenjungs', articles), 'strassenjungs');
    });

    test('keeps letters it has no base letter for', () {
      expect(artistSortKey('Мумий Тролль', articles), 'мумий тролль');
      expect(artistSortKey('坂本龍一', articles), '坂本龍一');
    });
  });

  group('parseIgnoredArticles', () {
    test('splits on spaces', () {
      expect(parseIgnoredArticles('The El  La'), ['The', 'El', 'La']);
    });

    test('is empty without the attribute', () {
      expect(parseIgnoredArticles(null), isEmpty);
      expect(parseIgnoredArticles(''), isEmpty);
    });
  });
}
