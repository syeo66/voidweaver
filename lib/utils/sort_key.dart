/// The key to sort the artist [name] by: lowercase, without accents, and
/// without a leading article from [articles] (the server's
/// `ignoredArticles`, e.g. `The El La`), so "The Beatles" sorts under B and
/// "Élodie" next to "Elton John" rather than after Z.
String artistSortKey(String name, Iterable<String> articles) {
  var key = foldAccents(name.trim().toLowerCase());
  for (final article in articles) {
    final prefix = '${foldAccents(article.toLowerCase())} ';
    // Not a name that is only the article ("The The" keeps one)
    if (key.startsWith(prefix) && key.length > prefix.length) {
      key = key.substring(prefix.length).trimLeft();
      break;
    }
  }
  return key;
}

/// The articles of the server's `ignoredArticles` attribute, separated by
/// spaces; none if it's missing
List<String> parseIgnoredArticles(String? attribute) => [
  for (final article in (attribute ?? '').split(' '))
    if (article.isNotEmpty) article,
];

/// [text] (lowercase) with the accented Latin letters replaced by their base
/// letters, and ligatures by their letters (`æ` → `ae`, `ß` → `ss`)
String foldAccents(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    buffer.write(_folded[char] ?? char);
  }
  return buffer.toString();
}

const _accentGroups = {
  'a': 'àáâãäåāăą',
  'c': 'çćĉċč',
  'd': 'ďđð',
  'e': 'èéêëēĕėęě',
  'g': 'ĝğġģ',
  'h': 'ĥħ',
  'i': 'ìíîïĩīĭįı',
  'j': 'ĵ',
  'k': 'ķ',
  'l': 'ĺļľŀł',
  'n': 'ñńņň',
  'o': 'òóôõöøōŏő',
  'r': 'ŕŗř',
  's': 'śŝşšș',
  't': 'ţťŧț',
  'u': 'ùúûüũūŭůűų',
  'w': 'ŵ',
  'y': 'ýÿŷ',
  'z': 'źżž',
  'ae': 'æ',
  'oe': 'œ',
  'ss': 'ß',
  'th': 'þ',
};

final _folded = {
  for (final MapEntry(key: base, value: accented) in _accentGroups.entries)
    for (final char in accented.split('')) char: base,
};
