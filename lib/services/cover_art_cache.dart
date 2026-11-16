import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

final _log = Logger('cover_art_cache');

/// What the downloads of cover art need from the login they fetch for;
/// implemented by `SubsonicApi`, which owns the cache.
abstract interface class CoverArtLogin {
  /// Whether the server refused the credentials, see
  /// `SubsonicApi.hasRejectedCredentials`
  bool get hasRejectedCredentials;

  /// The `User-Agent` of the app's requests
  String get userAgent;

  /// Whether [body], a document the server answered with instead of an
  /// image, refuses the credentials; sets the login's flag then
  bool checkRefusal(String body);
}

/// How many cover images the disk cache keeps, and for how long it keeps
/// one that isn't used. The default manager holds 200 for 30 days, which
/// scrolling through a library's album grid (each cover at one or two
/// sizes) would push out, so covers wouldn't stay available offline. A
/// cover is 5 to 300 KB depending on its size, so this stays well below a
/// few hundred MB.
@visibleForTesting
const maxCachedCoverArt = 3000;
@visibleForTesting
const cachedCoverArtLifetime = Duration(days: 90);

/// The disk cache of the cover art of [login]. Every login has its own
/// object, over the same files (keys include the server, see
/// `SubsonicApi.coverArtCacheKey`).
CacheManager createCoverArtCache(CoverArtLogin login) => CacheManager(
  Config(
    'voidweaverCoverArt',
    stalePeriod: cachedCoverArtLifetime,
    maxNrOfCacheObjects: maxCachedCoverArt,
    fileService: CoverArtFileService(login),
  ),
);

/// Fetches cover art for a login's disk cache ([SubsonicApi.coverArtCache]),
/// which stores every response with HTTP 200 as the image, for a week unless the server
/// says otherwise. A Subsonic server reports errors (also a rejected
/// password) with HTTP 200 and an XML document; stored, such a cover would
/// show as broken until then. So a document is an error here, as for the
/// player's audio (`ErrorDocumentGuard`).
///
/// For its [login], it also
/// - fetches nothing while the server rejects the credentials
///   ([CoverArtLogin.hasRejectedCredentials]): every cover of a scrolled list
///   would be another failed login. Covers already cached still show.
/// - sets the login's `credentialsRejected` when a cover is refused for the
///   credentials, see [CoverArtLogin.checkRefusal]
/// - sends its `User-Agent` ([CoverArtLogin.userAgent])
class CoverArtFileService extends FileService {
  CoverArtFileService(this._login, {http.Client? httpClient})
    : _client = httpClient ?? http.Client();

  final CoverArtLogin _login;
  final http.Client _client;

  // A Subsonic error response is a few hundred bytes
  static const _maxDocumentBytes = 16 * 1024;

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final login = _login;
    if (login.hasRejectedCredentials) {
      throw const HttpException('Credentials rejected, cover art not fetched');
    }
    final request = http.Request('GET', Uri.parse(url));
    if (headers != null) request.headers.addAll(headers);
    request.headers['User-Agent'] = login.userAgent;
    final response = await _client.send(request);
    final type = response.headers['content-type'];
    if (response.statusCode == 200 && type != null && isDocument(type)) {
      final body = await _readStart(response.stream);
      final refused = login.checkRefusal(body);
      _log.fine(
        () =>
            'Got a document ($type) instead of cover art'
            '${refused ? ': credentials rejected' : ''}',
      );
      throw HttpException(
        refused
            ? 'Cover art refused: credentials rejected'
            : 'Got a document ($type) instead of cover art',
      );
    }
    return HttpGetResponse(response, request.url);
  }

  /// Whether [contentType] is a document rather than an image: XML or JSON
  /// (a Subsonic error) or any text (a reverse proxy's page), but no image
  /// type (`image/svg+xml`). Not a list of image types, which would fail art
  /// a server sends under a type nobody thought of
  /// (application/octet-stream, ...).
  @visibleForTesting
  static bool isDocument(String contentType) {
    final type = contentType.trim().toLowerCase();
    if (type.startsWith('image/')) return false;
    return type.startsWith('text/') ||
        type.contains('xml') ||
        type.contains('json');
  }

  /// The start of [stream], up to [_maxDocumentBytes]; the rest isn't read.
  static Future<String> _readStart(Stream<List<int>> stream) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      bytes.add(chunk);
      if (bytes.length >= _maxDocumentBytes) break;
    }
    final read = bytes.toBytes();
    return utf8.decode(
      read.length > _maxDocumentBytes
          ? read.sublist(0, _maxDocumentBytes)
          : read,
      allowMalformed: true,
    );
  }
}
