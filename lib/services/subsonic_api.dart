import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:xml/xml.dart';
import 'package:logging/logging.dart';
import '../models/album_list_type.dart';
import '../models/subsonic_models.dart';
import 'api_cache.dart';
import 'network_config.dart';
import 'network_errors.dart';
import 'network_retry.dart';
import 'replaygain_reader.dart';

export '../models/subsonic_models.dart';

final _log = Logger('subsonic_api');

/// An error the server reported in a `status="failed"` response. Subsonic
/// servers answer with HTTP 200 even then (wrong password, unknown id).
class SubsonicException implements Exception {
  /// Subsonic error code, e.g. 40 for a wrong username or password
  final int? code;
  final String message;

  const SubsonicException(this.code, this.message);

  /// Whether the request was refused because of the credentials (wrong
  /// password, unsupported or conflicting auth), not because of the request
  /// itself.
  bool get isAuthError => code != null && code! >= 40 && code! <= 44;

  @override
  String toString() => message;
}

class SubsonicApi {
  final String serverUrl;
  final String username;
  final String password;
  final String clientName = 'voidweaver';
  final String version = '1.16.1';
  final ApiCache _cache = ApiCache();
  late HttpClient _innerClient;
  late http.Client _httpClient;
  late NetworkRetryService _retryService;
  NetworkConfig _networkConfig;

  SubsonicApi({
    required this.serverUrl,
    required this.username,
    required this.password,
    NetworkConfig? networkConfig,
  }) : _networkConfig = networkConfig ?? NetworkConfig.defaultConfig {
    // Enforce HTTPS for security
    final uri = Uri.tryParse(serverUrl);
    if (uri == null || uri.scheme.toLowerCase() != 'https') {
      throw ArgumentError('Server URL must use HTTPS protocol for security');
    }

    _initializeHttpClient();
  }

  void _initializeHttpClient() {
    _innerClient = HttpClient()
      ..connectionTimeout = _networkConfig.connectionTimeout
      ..maxConnectionsPerHost = 8;
    _httpClient = IOClient(_innerClient);

    _retryService = NetworkRetryService(
      config: _networkConfig,
      httpClient: _httpClient,
    );
  }

  String _generateSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (i) => random.nextInt(256));
    return base64Encode(bytes);
  }

  String _generateToken(String salt) {
    final combined = password + salt;
    final bytes = utf8.encode(combined);
    final digest = md5.convert(bytes);
    return digest.toString();
  }

  Map<String, String> _getAuthParams() {
    final salt = _generateSalt();
    final token = _generateToken(salt);

    return {
      'u': username,
      't': token,
      's': salt,
      'v': version,
      'c': clientName,
      'f': 'xml',
    };
  }

  Future<XmlDocument> _makeRequest(
    String endpoint, [
    Map<String, String>? extraParams,
    NetworkRequestType requestType = NetworkRequestType.metadata,
  ]) async {
    return _parseBody(await _fetchBody(endpoint, extraParams, requestType));
  }

  /// Like [_makeRequest], but decodes and parses the response with [parse]
  /// on a background isolate. For responses that can be large (the whole
  /// library), which would otherwise stall the UI. [parse] must be a static
  /// or top-level function.
  Future<T> _makeLargeRequest<T>(
    String endpoint,
    Map<String, String>? extraParams,
    NetworkRequestType requestType,
    T Function(XmlDocument doc) parse,
  ) async {
    return parseInBackground(
        await _fetchBody(endpoint, extraParams, requestType), parse);
  }

  /// Parses [body] with [parse] on a background isolate. Static, so the
  /// closure sent to the isolate can't capture an API (and its HTTP client).
  @visibleForTesting
  static Future<T> parseInBackground<T>(
          Uint8List body, T Function(XmlDocument doc) parse) =>
      Isolate.run(() => parse(_parseBody(body)));

  static XmlDocument _parseBody(Uint8List body) =>
      parseResponse(utf8.decode(body, allowMalformed: true));

  /// The body of a successful response to [endpoint]
  Future<Uint8List> _fetchBody(
    String endpoint,
    Map<String, String>? extraParams,
    NetworkRequestType requestType,
  ) async {
    final params = _getAuthParams();
    if (extraParams != null) {
      params.addAll(extraParams);
    }

    final uri =
        Uri.parse('$serverUrl/rest/$endpoint').replace(queryParameters: params);

    try {
      final headers = {
        'Content-Type': 'application/xml',
        'User-Agent': 'voidweaver/1.0',
      };

      final response = await _retryService.getWithRetry(
        uri,
        headers: headers,
        requestType: requestType,
        contextDescription: 'Subsonic API: $endpoint',
      );

      if (response.statusCode == 200) {
        return response.bodyBytes;
      } else {
        // Not the body: it can be a whole HTML error page
        throw HttpStatusException(response.statusCode);
      }
    } on NetworkTimeoutException catch (e) {
      _log.warning('Request timeout: $uri', e);
      rethrow;
    } on NetworkConnectionException catch (e) {
      _log.warning('Connection error: $uri', e);
      rethrow;
    } on HttpStatusException {
      rethrow;
    } on SocketException {
      rethrow;
    } on TlsException {
      rethrow;
    } catch (e) {
      // Rethrown as it is, so callers can still tell it by its type. Its
      // message can contain the request URL, which the log redacts; the UI
      // shows errors through NetworkErrorHelper, never their message.
      _log.warning('Network request failed: $uri', e);
      rethrow;
    }
  }

  /// Parses a response body, throwing [SubsonicException] if the server
  /// reported an error.
  @visibleForTesting
  static XmlDocument parseResponse(String body) {
    final doc = XmlDocument.parse(body);
    final root = doc.rootElement;
    if (root.getAttribute('status') == 'failed') {
      final error = root.getElement('error');
      throw SubsonicException(
        int.tryParse(error?.getAttribute('code') ?? ''),
        error?.getAttribute('message') ?? 'The server reported an error',
      );
    }
    return doc;
  }

  /// Checks that the server is reachable and accepts the credentials.
  Future<void> ping() async {
    await _makeRequest('ping', null, NetworkRequestType.connection);
  }

  static Object? _albumsToJson(List<Album> albums) =>
      albums.map((a) => a.toJson()).toList();

  @visibleForTesting
  static List<Album> albumsFromXml(XmlDocument doc) => [
        for (final element in doc.findAllElements('album'))
          Album.fromXml(element)
      ];

  static List<Album> _albumsFromJson(dynamic json) => (json as List<dynamic>)
      .map((a) => Album.fromJson(a as Map<String, dynamic>))
      .toList();

  /// Albums per getAlbumList2 request, the most the Subsonic API allows
  static const _albumPageSize = 500;

  /// Albums in the order of [type]. With [forceRefresh] they're fetched from
  /// the server even if the cached list hasn't expired yet.
  ///
  /// [AlbumListType.newest] is every album, fetched page by page. An expired
  /// list is only fetched again if the server scanned the library since, see
  /// [getLibraryVersion].
  ///
  /// [AlbumListType.recent] is only the first page: its order changes with
  /// every play, so it's fetched again whenever it expires, and nobody
  /// scrolls past the last 500 albums played.
  Future<List<Album>> getAlbumList(
      {AlbumListType type = AlbumListType.recent,
      bool forceRefresh = false}) async {
    Future<List<Album>> fetchPage(int offset) => _makeLargeRequest(
        'getAlbumList2',
        {
          'type': type.name,
          'size': '$_albumPageSize',
          'offset': '$offset',
        },
        NetworkRequestType.metadata,
        albumsFromXml);

    return await _cache.getOrFetch<List<Album>>(
      'getAlbumList2',
      {'type': type.name, 'size': '$_albumPageSize'},
      () => type == AlbumListType.newest
          ? fetchAllAlbumPages(fetchPage)
          : fetchPage(0),
      cacheDuration: const Duration(minutes: 3),
      usePersistentCache: true,
      forceRefresh: forceRefresh,
      toJson: _albumsToJson,
      fromJson: _albumsFromJson,
      version: type == AlbumListType.newest ? getLibraryVersion : null,
    );
  }

  /// Identifies the state of the library on the server; it changes whenever
  /// a scan finishes. Null if the server doesn't tell (only Navidrome and
  /// some others report the last scan) or is scanning right now.
  Future<String?> getLibraryVersion() async {
    final XmlDocument doc;
    try {
      doc = await _makeRequest(
          'getScanStatus', null, NetworkRequestType.metadata);
    } on SubsonicException catch (e) {
      // Not supported, or not allowed for this user
      _log.fine('getScanStatus failed', e);
      return null;
    }
    return libraryVersionFrom(doc);
  }

  @visibleForTesting
  static String? libraryVersionFrom(XmlDocument doc) {
    final status = doc.findAllElements('scanStatus').firstOrNull;
    final lastScan = status?.getAttribute('lastScan');
    if (status == null ||
        lastScan == null ||
        status.getAttribute('scanning') == 'true') {
      return null;
    }
    return '$lastScan/${status.getAttribute('count')}';
  }

  /// Requests pages of albums from [fetchPage] (given the offset) until one
  /// comes back short. Albums already seen are dropped: a server that ignores
  /// the offset returns the first page again, which ends the loop, and an
  /// album added between requests shifts the pages by one.
  @visibleForTesting
  static Future<List<Album>> fetchAllAlbumPages(
      Future<List<Album>> Function(int offset) fetchPage,
      {int pageSize = _albumPageSize}) async {
    final albums = <Album>[];
    final seen = <String>{};
    while (true) {
      final page = await fetchPage(albums.length);
      final added = [
        for (final album in page)
          if (seen.add(album.id)) album
      ];
      albums.addAll(added);
      if (page.length < pageSize || added.isEmpty) return albums;
    }
  }

  Future<Album> getAlbum(String id) async {
    return await _cache.getOrFetch<Album>(
      'getAlbum',
      {'id': id},
      () async {
        try {
          final doc = await _makeRequest(
              'getAlbum', {'id': id}, NetworkRequestType.metadata);
          final albumElements = doc.findAllElements('album');
          if (albumElements.isEmpty) {
            // Debug: log the full response to understand the structure
            _log.fine(
                () => 'getAlbum response for ID $id: ${doc.toXmlString()}');
            throw const UserFacingException('Album not found');
          }
          return Album.fromXml(albumElements.first);
        } catch (e) {
          _log.warning('getAlbum failed for ID $id', e);
          rethrow;
        }
      },
      cacheDuration: const Duration(minutes: 10),
      usePersistentCache: true,
      toJson: (album) => album.toJson(),
      fromJson: (json) => Album.fromJson(json as Map<String, dynamic>),
    );
  }

  /// A fresh pick of random songs on every call. Not cached: subsoxy weights
  /// each pick by the listening history, so a repeated call must reach it.
  Future<List<Song>> getRandomSongs([int count = 50]) async {
    final doc =
        await _makeRequest('getRandomSongs', {'size': count.toString()});
    return [
      for (final element in doc.findAllElements('song')) Song.fromXml(element)
    ];
  }

  String getStreamUrl(String id) {
    final params = _getAuthParams();
    params['id'] = id;

    final uri =
        Uri.parse('$serverUrl/rest/stream').replace(queryParameters: params);
    return uri.toString();
  }

  /// ReplayGain tags of the song [id], read from the start of its file, for
  /// songs the server sends no ReplayGain data for. No data after a few
  /// seconds, see [ReplayGainReader.readFromUrl].
  Future<ReplayGainData> readReplayGain(String id) =>
      ReplayGainReader.readFromUrl(getStreamUrl(id), client: _httpClient);

  /// URL of the cover art [id], scaled by the server to [size] pixels
  String getCoverArtUrl(String id, {int size = 300}) {
    final params = _getAuthParams();
    params['id'] = id;
    params['size'] = '$size';

    final uri = Uri.parse('$serverUrl/rest/getCoverArt')
        .replace(queryParameters: params);
    return uri.toString();
  }

  /// Image cache key (disk and memory) for the cover art [id] at [size]. Not
  /// the URL, whose token changes with every request, and not the id alone,
  /// because ids like `al-1` repeat across servers.
  String coverArtCacheKey(String id, {int size = 300}) =>
      '$serverUrl#$id@$size';

  /// Notifies the server that a song is now playing.
  /// This updates the "now playing" status but doesn't affect play counts.
  /// Throws on failure; use [ScrobbleQueue] rather than calling this directly.
  Future<void> scrobbleNowPlaying(String songId) async {
    final params = {
      'id': songId,
      'submission': 'false',
    };

    await _makeRequest('scrobble', params);
    _log.fine('Now playing notification sent for song: $songId');
  }

  /// Submits a scrobble for a played song.
  /// This updates play counts and last played timestamp.
  /// Throws on failure, so [ScrobbleQueue] can keep the request and retry.
  Future<void> scrobbleSubmission(String songId, {DateTime? playedAt}) async {
    final params = {
      'id': songId,
      'submission': 'true',
    };

    // Add timestamp if provided (milliseconds since epoch)
    if (playedAt != null) {
      params['time'] = playedAt.millisecondsSinceEpoch.toString();
    }

    await _makeRequest('scrobble', params);
    _log.info('Scrobble submission sent for song: $songId');
  }

  /// Searches for artists, albums, and songs.
  /// Returns a SearchResult containing separate lists for each type.
  Future<SearchResult> search(String query,
      {int artistCount = 20, int albumCount = 20, int songCount = 20}) async {
    return await _cache.getOrFetch<SearchResult>(
      'search3',
      {
        'query': query,
        'artistCount': artistCount.toString(),
        'albumCount': albumCount.toString(),
        'songCount': songCount.toString(),
      },
      () async {
        try {
          final params = {
            'query': query,
            'artistCount': artistCount.toString(),
            'albumCount': albumCount.toString(),
            'songCount': songCount.toString(),
          };

          final doc = await _makeRequest(
              'search3', params, NetworkRequestType.metadata);

          return SearchResult.fromXml(doc);
        } catch (e) {
          _log.warning('Search failed', e);
          rethrow;
        }
      },
      // Only in memory: every query would add an entry that's never read
      // again
      cacheDuration: const Duration(minutes: 5),
    );
  }

  /// Gets all artists from the server.
  /// Returns a list of Artist objects ordered alphabetically.
  Future<List<Artist>> getArtists() async {
    return await _cache.getOrFetch<List<Artist>>(
      'getArtists',
      null,
      () async {
        try {
          return await _makeLargeRequest('getArtists', null,
              NetworkRequestType.metadata, _sortedArtistsFromXml);
        } catch (e) {
          _log.warning('Failed to get artists', e);
          rethrow;
        }
      },
      cacheDuration: const Duration(minutes: 15),
      usePersistentCache: true,
      toJson: (artists) => artists.map((a) => a.toJson()).toList(),
      fromJson: (json) => (json as List<dynamic>)
          .map((a) => Artist.fromJson(a as Map<String, dynamic>))
          .toList(),
    );
  }

  static List<Artist> _sortedArtistsFromXml(XmlDocument doc) => [
        for (final element in doc.findAllElements('artist'))
          Artist.fromXml(element)
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  /// Gets all albums for a specific artist.
  /// Returns a list of Album objects for the given artist ID.
  Future<List<Album>> getArtistAlbums(String artistId) async {
    return await _cache.getOrFetch<List<Album>>(
      'getArtist',
      {'id': artistId},
      () async {
        try {
          final doc = await _makeRequest('getArtist', {'id': artistId});
          final albums = <Album>[];

          final albumElements = doc.findAllElements('album');
          for (final element in albumElements) {
            albums.add(Album.fromXml(element));
          }

          return albums;
        } catch (e) {
          _log.warning('Failed to get albums for artist $artistId', e);
          rethrow;
        }
      },
      cacheDuration: const Duration(minutes: 10),
      usePersistentCache: true,
      toJson: _albumsToJson,
      fromJson: _albumsFromJson,
    );
  }

  /// Clear all cached data
  Future<void> clearCache() async {
    await _cache.clearAll();
  }

  /// Timeouts and retry settings of the requests
  NetworkConfig get networkConfig => _networkConfig;

  /// Applies new timeouts and retry settings to the requests from now on.
  /// The connection timeout belongs to the HTTP client, so it's replaced;
  /// closing the old one lets requests that are already running finish.
  set networkConfig(NetworkConfig config) {
    if (config == _networkConfig) return;
    final oldClient = _innerClient;
    final oldRetryService = _retryService;
    _networkConfig = config;
    _initializeHttpClient();
    oldRetryService.dispose();
    // Not IOClient.close(), which aborts the running requests
    oldClient.close();
  }

  /// Dispose the HTTP client and clean up resources
  void dispose() {
    _retryService.dispose();
    _httpClient.close();
  }
}
