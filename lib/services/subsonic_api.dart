import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http_plus/http_plus.dart' as http_plus;
import 'package:xml/xml.dart';
import 'api_cache.dart';
import 'network_config.dart';
import 'network_errors.dart';
import 'network_retry.dart';
import 'replaygain_debug_logger.dart';
import '../utils/redact.dart';

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
  late http_plus.HttpPlusClient _httpClient;
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
    _httpClient = http_plus.HttpPlusClient(
      enableHttp2: true,
      maxOpenConnections: 8,
      connectionTimeout: _networkConfig.connectionTimeout,
    );

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
        // Properly decode UTF-8 bytes with malformed character handling
        String responseBody;
        try {
          responseBody = utf8.decode(response.bodyBytes, allowMalformed: true);
        } catch (e) {
          // Fallback to response.body if utf8.decode fails
          responseBody = response.body;
        }
        return parseResponse(responseBody);
      } else {
        // Not the body: it can be a whole HTML error page
        throw HttpException('HTTP ${response.statusCode}');
      }
    } on SubsonicException {
      rethrow;
    } on NetworkTimeoutException catch (e) {
      if (kDebugMode) {
        debugPrint(redactCredentials('Request timeout: $uri - $e'));
      }
      rethrow;
    } on NetworkConnectionException catch (e) {
      if (kDebugMode) {
        debugPrint(redactCredentials('Connection error: $uri - $e'));
      }
      rethrow;
    } on HttpException catch (e) {
      // Without its URL, which carries the credentials
      throw HttpException(e.message);
    } on SocketException {
      rethrow;
    } on TlsException {
      rethrow;
    } on XmlException {
      rethrow;
    } catch (e) {
      if (kDebugMode) {
        debugPrint(redactCredentials('Network request failed: $uri - $e'));
      }
      // Other errors (e.g. the client's) can contain the request URL
      throw Exception(redactCredentials('Network error: $e'));
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

  static List<Album> _albumsFromJson(dynamic json) => (json as List<dynamic>)
      .map((a) => Album.fromJson(a as Map<String, dynamic>))
      .toList();

  /// Albums per getAlbumList2 request, the most the Subsonic API allows
  static const _albumPageSize = 500;

  /// All albums, most recently added first, fetched page by page. With
  /// [forceRefresh] they're fetched from the server even if the cached list
  /// hasn't expired yet. Otherwise an expired list is only fetched again if
  /// the server scanned the library since, see [getLibraryVersion].
  Future<List<Album>> getAlbumList({bool forceRefresh = false}) async {
    return await _cache.getOrFetch<List<Album>>(
      'getAlbumList2',
      {'type': 'newest', 'size': '$_albumPageSize'},
      () {
        // The list used to be fetched sorted by last play (type=recent)
        _cache.clearEntry(
            'getAlbumList2', {'type': 'recent', 'size': '$_albumPageSize'});
        return fetchAllAlbumPages((offset) async {
          final doc = await _makeRequest(
              'getAlbumList2',
              {
                'type': 'newest',
                'size': '$_albumPageSize',
                'offset': '$offset',
              },
              NetworkRequestType.metadata);
          return [
            for (final element in doc.findAllElements('album'))
              Album.fromXml(element)
          ];
        });
      },
      cacheDuration: const Duration(minutes: 3),
      usePersistentCache: true,
      forceRefresh: forceRefresh,
      toJson: _albumsToJson,
      fromJson: _albumsFromJson,
      version: getLibraryVersion,
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
      debugPrint('getScanStatus failed: $e');
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
            debugPrint('getAlbum response for ID $id: ${doc.toXmlString()}');
            throw const UserFacingException('Album not found');
          }
          return Album.fromXml(albumElements.first);
        } catch (e) {
          debugPrint('getAlbum failed for ID $id: $e');
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

  String getCoverArtUrl(String id) {
    final params = _getAuthParams();
    params['id'] = id;
    params['size'] = '300';

    final uri = Uri.parse('$serverUrl/rest/getCoverArt')
        .replace(queryParameters: params);
    return uri.toString();
  }

  /// Notifies the server that a song is now playing.
  /// This updates the "now playing" status but doesn't affect play counts.
  /// Throws on failure; use [ScrobbleQueue] rather than calling this directly.
  Future<void> scrobbleNowPlaying(String songId) async {
    final params = {
      'id': songId,
      'submission': 'false',
    };

    await _makeRequest('scrobble', params);
    debugPrint('Now playing notification sent for song: $songId');
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
    debugPrint('Scrobble submission sent for song: $songId');
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

          // Debug: Print the XML response to understand the structure
          if (kDebugMode) {
            debugPrint('Search response: ${doc.toXmlString()}');
          }

          return SearchResult.fromXml(doc);
        } catch (e) {
          debugPrint('Search failed: $e');
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
          final doc = await _makeRequest('getArtists');
          final artists = <Artist>[];

          final artistElements = doc.findAllElements('artist');
          for (final element in artistElements) {
            artists.add(Artist.fromXml(element));
          }

          // Sort artists alphabetically by name
          artists.sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

          return artists;
        } catch (e) {
          debugPrint('Failed to get artists: $e');
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
          debugPrint('Failed to get albums for artist $artistId: $e');
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
    final oldClient = _httpClient;
    final oldRetryService = _retryService;
    _networkConfig = config;
    _initializeHttpClient();
    oldRetryService.dispose();
    oldClient.close();
  }

  /// Dispose the HTTP client and clean up resources
  void dispose() {
    _retryService.dispose();
    _httpClient.close();
  }
}

class Album {
  final String id;
  final String name;
  final String artist;
  final String? artistId;
  final String? coverArt;
  final int? songCount;
  final int? duration;
  final DateTime? created;
  final List<Song> songs;

  Album({
    required this.id,
    required this.name,
    required this.artist,
    this.artistId,
    this.coverArt,
    this.songCount,
    this.duration,
    this.created,
    this.songs = const [],
  });

  factory Album.fromXml(XmlElement element) {
    final songs = <Song>[];
    final songElements = element.findElements('song');
    for (final songElement in songElements) {
      songs.add(Song.fromXml(songElement));
    }

    return Album(
      id: element.getAttribute('id') ?? '',
      name: element.getAttribute('name') ?? '',
      artist: element.getAttribute('artist') ?? '',
      artistId: element.getAttribute('artistId'),
      coverArt: element.getAttribute('coverArt'),
      songCount: int.tryParse(element.getAttribute('songCount') ?? ''),
      duration: int.tryParse(element.getAttribute('duration') ?? ''),
      created: DateTime.tryParse(element.getAttribute('created') ?? ''),
      songs: songs,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Album &&
        other.id == id &&
        other.name == name &&
        other.artist == artist &&
        other.artistId == artistId &&
        other.coverArt == coverArt &&
        other.songCount == songCount &&
        other.duration == duration &&
        other.created == created &&
        _listEquals(other.songs, songs);
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      name,
      artist,
      artistId,
      coverArt,
      songCount,
      duration,
      created,
      Object.hashAll(songs),
    );
  }

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'artist': artist,
      'artistId': artistId,
      'coverArt': coverArt,
      'songCount': songCount,
      'duration': duration,
      'created': created?.toIso8601String(),
      'songs': songs.map((song) => song.toJson()).toList(),
    };
  }

  static Album fromJson(Map<String, dynamic> json) {
    return Album(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      artistId: json['artistId'] as String?,
      coverArt: json['coverArt'] as String?,
      songCount: json['songCount'] as int?,
      duration: json['duration'] as int?,
      created: json['created'] != null
          ? DateTime.tryParse(json['created'] as String)
          : null,
      songs: (json['songs'] as List<dynamic>?)
              ?.map(
                  (songJson) => Song.fromJson(songJson as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// Logs to both the console (debug builds) and the persistent ReplayGain
/// debug log (only when the user has enabled it in Settings).
void _rgLog(String message) {
  debugPrint(message);
  ReplayGainDebugLogger.instance.log(message);
}

class Song {
  final String id;
  final String title;
  final String artist;
  final String album;
  final String? albumId;
  final String? coverArt;
  final int? duration;
  final int? track;
  final String? contentType;
  final String? suffix;
  final double? replayGainTrackGain;
  final double? replayGainAlbumGain;
  final double? replayGainTrackPeak;
  final double? replayGainAlbumPeak;

  Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    this.albumId,
    this.coverArt,
    this.duration,
    this.track,
    this.contentType,
    this.suffix,
    this.replayGainTrackGain,
    this.replayGainAlbumGain,
    this.replayGainTrackPeak,
    this.replayGainAlbumPeak,
  });

  Song copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    String? albumId,
    String? coverArt,
    int? duration,
    int? track,
    String? contentType,
    String? suffix,
    double? replayGainTrackGain,
    double? replayGainAlbumGain,
    double? replayGainTrackPeak,
    double? replayGainAlbumPeak,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      albumId: albumId ?? this.albumId,
      coverArt: coverArt ?? this.coverArt,
      duration: duration ?? this.duration,
      track: track ?? this.track,
      contentType: contentType ?? this.contentType,
      suffix: suffix ?? this.suffix,
      replayGainTrackGain: replayGainTrackGain ?? this.replayGainTrackGain,
      replayGainAlbumGain: replayGainAlbumGain ?? this.replayGainAlbumGain,
      replayGainTrackPeak: replayGainTrackPeak ?? this.replayGainTrackPeak,
      replayGainAlbumPeak: replayGainAlbumPeak ?? this.replayGainAlbumPeak,
    );
  }

  factory Song.fromXml(XmlElement element) {
    final songId = element.getAttribute('id') ?? '';
    final title = element.getAttribute('title') ?? '';
    final albumId = element.getAttribute('albumId');
    final coverArt = element.getAttribute('coverArt') ?? albumId;

    // OpenSubsonic servers (e.g. Navidrome) return ReplayGain as a nested
    // <replayGain trackGain="..." albumGain="..." .../> child element.
    // Use findElements() instead of getElement() to ignore XML namespaces.
    final replayGainElements = element.findElements('replayGain');
    final replayGainElement =
        replayGainElements.isNotEmpty ? replayGainElements.first : null;

    // Debug logging for ReplayGain parsing (only recorded when the user has
    // enabled ReplayGain debug logging in Settings)
    _rgLog('[ReplayGain XML] Parsing song: $title (id=$songId)');
    _rgLog(
        '[ReplayGain XML] Found ${replayGainElements.length} replayGain elements');
    if (replayGainElement != null) {
      _rgLog('[ReplayGain XML] ReplayGain element attributes:');
      _rgLog(
          '[ReplayGain XML]   trackGain=${replayGainElement.getAttribute('trackGain')}');
      _rgLog(
          '[ReplayGain XML]   albumGain=${replayGainElement.getAttribute('albumGain')}');
      _rgLog(
          '[ReplayGain XML]   trackPeak=${replayGainElement.getAttribute('trackPeak')}');
      _rgLog(
          '[ReplayGain XML]   albumPeak=${replayGainElement.getAttribute('albumPeak')}');
    } else {
      _rgLog('[ReplayGain XML] No nested <replayGain> element; flat attrs: '
          'replayGainTrackGain=${element.getAttribute('replayGainTrackGain')}, '
          'rgTrackGain=${element.getAttribute('rgTrackGain')}, '
          'trackGain=${element.getAttribute('trackGain')}, '
          'replayGainAlbumGain=${element.getAttribute('replayGainAlbumGain')}, '
          'rgAlbumGain=${element.getAttribute('rgAlbumGain')}, '
          'albumGain=${element.getAttribute('albumGain')}');
    }

    final song = Song(
      id: songId,
      title: title,
      artist: element.getAttribute('artist') ?? '',
      album: element.getAttribute('album') ?? '',
      albumId: albumId,
      coverArt: coverArt,
      duration: int.tryParse(element.getAttribute('duration') ?? ''),
      track: int.tryParse(element.getAttribute('track') ?? ''),
      contentType: element.getAttribute('contentType'),
      suffix: element.getAttribute('suffix'),
      // Try nested <replayGain> child element first (OpenSubsonic extension),
      // then fall back to attributes on the song element for other servers.
      replayGainTrackGain: double.tryParse(
              replayGainElement?.getAttribute('trackGain') ?? '') ??
          double.tryParse(element.getAttribute('replayGainTrackGain') ?? '') ??
          double.tryParse(element.getAttribute('rgTrackGain') ?? '') ??
          double.tryParse(element.getAttribute('trackGain') ?? ''),
      replayGainAlbumGain: double.tryParse(
              replayGainElement?.getAttribute('albumGain') ?? '') ??
          double.tryParse(element.getAttribute('replayGainAlbumGain') ?? '') ??
          double.tryParse(element.getAttribute('rgAlbumGain') ?? '') ??
          double.tryParse(element.getAttribute('albumGain') ?? ''),
      replayGainTrackPeak: double.tryParse(
              replayGainElement?.getAttribute('trackPeak') ?? '') ??
          double.tryParse(element.getAttribute('replayGainTrackPeak') ?? '') ??
          double.tryParse(element.getAttribute('rgTrackPeak') ?? '') ??
          double.tryParse(element.getAttribute('trackPeak') ?? ''),
      replayGainAlbumPeak: double.tryParse(
              replayGainElement?.getAttribute('albumPeak') ?? '') ??
          double.tryParse(element.getAttribute('replayGainAlbumPeak') ?? '') ??
          double.tryParse(element.getAttribute('rgAlbumPeak') ?? '') ??
          double.tryParse(element.getAttribute('albumPeak') ?? ''),
    );

    // Debug logging for final parsed values
    _rgLog(
        '[ReplayGain XML] Final parsed values for "${song.title}" (id=${song.id}): '
        'trackGain=${song.replayGainTrackGain}, albumGain=${song.replayGainAlbumGain}, '
        'trackPeak=${song.replayGainTrackPeak}, albumPeak=${song.replayGainAlbumPeak}');

    return song;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Song &&
        other.id == id &&
        other.title == title &&
        other.artist == artist &&
        other.album == album &&
        other.albumId == albumId &&
        other.coverArt == coverArt &&
        other.duration == duration &&
        other.track == track &&
        other.contentType == contentType &&
        other.suffix == suffix &&
        other.replayGainTrackGain == replayGainTrackGain &&
        other.replayGainAlbumGain == replayGainAlbumGain &&
        other.replayGainTrackPeak == replayGainTrackPeak &&
        other.replayGainAlbumPeak == replayGainAlbumPeak;
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      title,
      artist,
      album,
      albumId,
      coverArt,
      duration,
      track,
      contentType,
      suffix,
      replayGainTrackGain,
      replayGainAlbumGain,
      replayGainTrackPeak,
      replayGainAlbumPeak,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'albumId': albumId,
      'coverArt': coverArt,
      'duration': duration,
      'track': track,
      'contentType': contentType,
      'suffix': suffix,
      'replayGainTrackGain': replayGainTrackGain,
      'replayGainAlbumGain': replayGainAlbumGain,
      'replayGainTrackPeak': replayGainTrackPeak,
      'replayGainAlbumPeak': replayGainAlbumPeak,
    };
  }

  static Song fromJson(Map<String, dynamic> json) {
    // Parse ReplayGain data - support both flat and nested formats
    // Nested format (Navidrome/OpenSubsonic): {"replayGain": {"trackGain": -12.61, ...}}
    // Flat format (legacy): {"replayGainTrackGain": -12.61, ...}
    double? trackGain;
    double? albumGain;
    double? trackPeak;
    double? albumPeak;

    if (json.containsKey('replayGain') && json['replayGain'] is Map) {
      final replayGain = json['replayGain'] as Map<String, dynamic>;
      trackGain = (replayGain['trackGain'] as num?)?.toDouble();
      albumGain = (replayGain['albumGain'] as num?)?.toDouble();
      trackPeak = (replayGain['trackPeak'] as num?)?.toDouble();
      albumPeak = (replayGain['albumPeak'] as num?)?.toDouble();
      _rgLog(
          '[ReplayGain JSON] "${json['title']}" (id=${json['id']}): nested replayGain='
          '{trackGain: $trackGain, albumGain: $albumGain, trackPeak: $trackPeak, albumPeak: $albumPeak}');
    } else {
      // Fallback to flat format for backwards compatibility
      trackGain = (json['replayGainTrackGain'] as num?)?.toDouble();
      albumGain = (json['replayGainAlbumGain'] as num?)?.toDouble();
      trackPeak = (json['replayGainTrackPeak'] as num?)?.toDouble();
      albumPeak = (json['replayGainAlbumPeak'] as num?)?.toDouble();
      _rgLog(
          '[ReplayGain JSON] "${json['title']}" (id=${json['id']}): flat fields='
          '{trackGain: $trackGain, albumGain: $albumGain, trackPeak: $trackPeak, albumPeak: $albumPeak}');
    }

    return Song(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      album: json['album'] as String? ?? '',
      albumId: json['albumId'] as String?,
      coverArt: json['coverArt'] as String?,
      duration: json['duration'] as int?,
      track: json['track'] as int?,
      contentType: json['contentType'] as String?,
      suffix: json['suffix'] as String?,
      replayGainTrackGain: trackGain,
      replayGainAlbumGain: albumGain,
      replayGainTrackPeak: trackPeak,
      replayGainAlbumPeak: albumPeak,
    );
  }
}

class Artist {
  final String id;
  final String name;
  final String? coverArt;
  final int? albumCount;

  Artist({
    required this.id,
    required this.name,
    this.coverArt,
    this.albumCount,
  });

  factory Artist.fromXml(XmlElement element) {
    return Artist(
      id: element.getAttribute('id') ?? '',
      name: element.getAttribute('name') ?? '',
      coverArt: element.getAttribute('coverArt'),
      albumCount: int.tryParse(element.getAttribute('albumCount') ?? ''),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Artist &&
        other.id == id &&
        other.name == name &&
        other.coverArt == coverArt &&
        other.albumCount == albumCount;
  }

  @override
  int get hashCode {
    return Object.hash(id, name, coverArt, albumCount);
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'coverArt': coverArt,
      'albumCount': albumCount,
    };
  }

  static Artist fromJson(Map<String, dynamic> json) {
    return Artist(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      coverArt: json['coverArt'] as String?,
      albumCount: json['albumCount'] as int?,
    );
  }
}

class SearchResult {
  final List<Artist> artists;
  final List<Album> albums;
  final List<Song> songs;

  SearchResult({
    required this.artists,
    required this.albums,
    required this.songs,
  });

  factory SearchResult.fromXml(XmlDocument doc) {
    // Try to find searchResult3 elements with and without namespace
    final searchResultElements = doc.findAllElements('searchResult3');

    final artists = <Artist>[];
    final albums = <Album>[];
    final songs = <Song>[];

    if (searchResultElements.isNotEmpty) {
      final searchResult = searchResultElements.first;

      final artistElements = searchResult.findAllElements('artist');
      if (kDebugMode) {
        debugPrint('Found ${artistElements.length} artists');
      }
      for (final element in artistElements) {
        artists.add(Artist.fromXml(element));
      }

      final albumElements = searchResult.findAllElements('album');
      if (kDebugMode) {
        debugPrint('Found ${albumElements.length} albums');
      }
      for (final element in albumElements) {
        albums.add(Album.fromXml(element));
      }

      final songElements = searchResult.findAllElements('song');
      if (kDebugMode) {
        debugPrint('Found ${songElements.length} songs');
      }
      for (final element in songElements) {
        songs.add(Song.fromXml(element));
      }
    } else {
      if (kDebugMode) {
        debugPrint('No searchResult3 elements found');
        debugPrint(
            'Available elements: ${doc.findAllElements('*').map((e) => e.name.local).toList()}');
      }
    }

    final result = SearchResult(
      artists: artists,
      albums: albums,
      songs: songs,
    );

    if (kDebugMode) {
      debugPrint(
          'SearchResult created: ${artists.length} artists, ${albums.length} albums, ${songs.length} songs');
      debugPrint('SearchResult isEmpty: ${result.isEmpty}');
    }

    return result;
  }

  bool get isEmpty => artists.isEmpty && albums.isEmpty && songs.isEmpty;
  bool get isNotEmpty => !isEmpty;
}
