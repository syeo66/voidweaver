import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http_plus/http_plus.dart' as http;
import 'package:xml/xml.dart';
import 'api_cache.dart';

class SubsonicApi {
  final String serverUrl;
  final String username;
  final String password;
  final String clientName = 'voidweaver';
  final String version = '1.16.1';
  final ApiCache _cache = ApiCache();
  late final http.HttpPlusClient _httpClient;

  SubsonicApi({
    required this.serverUrl,
    required this.username,
    required this.password,
  }) {
    _cache.initialize();
    _initializeHttpClient();
  }

  void _initializeHttpClient() {
    _httpClient = http.HttpPlusClient(
      enableHttp2: true,
      maxOpenConnections: 8,
      connectionTimeout: const Duration(seconds: 15),
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

  Future<XmlDocument> _makeRequest(String endpoint,
      [Map<String, String>? extraParams]) async {
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

      final response = await _httpClient.get(uri, headers: headers);

      if (response.statusCode == 200) {
        // Properly decode UTF-8 bytes with malformed character handling
        String responseBody;
        try {
          responseBody = utf8.decode(response.bodyBytes, allowMalformed: true);
        } catch (e) {
          // Fallback to response.body if utf8.decode fails
          responseBody = response.body;
        }
        return XmlDocument.parse(responseBody);
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Network request failed: $uri');
        print('Error: $e');
      }
      throw Exception('Network error: $e');
    }
  }

  Future<List<Album>> getAlbumList() async {
    return await _cache.getOrFetch<List<Album>>(
      'getAlbumList2',
      {'type': 'recent', 'size': '500'},
      () async {
        final doc = await _makeRequest(
            'getAlbumList2', {'type': 'recent', 'size': '500'});
        final albums = <Album>[];

        final albumElements = doc.findAllElements('album');
        for (final element in albumElements) {
          albums.add(Album.fromXml(element));
        }

        return albums;
      },
      cacheDuration: const Duration(minutes: 3),
      usePersistentCache: true,
    );
  }

  Future<Album> getAlbum(String id) async {
    return await _cache.getOrFetch<Album>(
      'getAlbum',
      {'id': id},
      () async {
        try {
          final doc = await _makeRequest('getAlbum', {'id': id});
          final albumElements = doc.findAllElements('album');
          if (albumElements.isEmpty) {
            // Debug: log the full response to understand the structure
            debugPrint('getAlbum response for ID $id: ${doc.toXmlString()}');
            throw Exception('Album not found: $id');
          }
          return Album.fromXml(albumElements.first);
        } catch (e) {
          debugPrint('getAlbum failed for ID $id: $e');
          rethrow;
        }
      },
      cacheDuration: const Duration(minutes: 10),
      usePersistentCache: true,
    );
  }

  Future<List<Song>> getRandomSongs([int count = 50]) async {
    return await _cache.getOrFetch<List<Song>>(
      'getRandomSongs',
      {'size': count.toString()},
      () async {
        final doc =
            await _makeRequest('getRandomSongs', {'size': count.toString()});
        final songs = <Song>[];

        final songElements = doc.findAllElements('song');
        for (final element in songElements) {
          songs.add(Song.fromXml(element));
        }

        return songs;
      },
      cacheDuration:
          const Duration(minutes: 1), // Random songs cache for shorter time
      usePersistentCache: false, // Don't persist random songs
    );
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
  Future<void> scrobbleNowPlaying(String songId) async {
    try {
      final params = {
        'id': songId,
        'submission': 'false',
      };

      await _makeRequest('scrobble', params);
      debugPrint('Now playing notification sent for song: $songId');
    } catch (e) {
      debugPrint('Failed to send now playing notification: $e');
      // Don't throw - we don't want to interrupt playback for scrobble failures
    }
  }

  /// Submits a scrobble for a played song.
  /// This updates play counts and last played timestamp.
  Future<void> scrobbleSubmission(String songId, {DateTime? playedAt}) async {
    try {
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
    } catch (e) {
      debugPrint('Failed to send scrobble submission: $e');
      // Don't throw - we don't want to interrupt playback for scrobble failures
    }
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

          final doc = await _makeRequest('search3', params);

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
      cacheDuration: const Duration(minutes: 5),
      usePersistentCache: true,
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
    );
  }

  /// Clear all cached data
  Future<void> clearCache() async {
    await _cache.clearAll();
  }

  /// Clear specific cache entry
  void clearCacheEntry(String endpoint, [Map<String, String>? params]) {
    _cache.clearEntry(endpoint, params);
  }

  /// Clear expired cache entries
  void clearExpiredCache() {
    _cache.clearExpired();
  }

  /// Get cache statistics
  Map<String, dynamic> getCacheStats() {
    return _cache.getStats();
  }

  /// Invalidate all album-related cache entries
  void invalidateAlbumCache() {
    _cache.invalidatePattern('getAlbumList');
    _cache.invalidatePattern('getAlbum');
  }

  /// Invalidate all artist-related cache entries
  void invalidateArtistCache() {
    _cache.invalidatePattern('getArtist');
  }

  /// Invalidate search cache entries
  void invalidateSearchCache() {
    _cache.invalidatePattern('search');
  }

  /// Dispose the HTTP client and clean up resources
  void dispose() {
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

  factory Song.fromXml(XmlElement element) {
    final songId = element.getAttribute('id') ?? '';
    final title = element.getAttribute('title') ?? '';
    final albumId = element.getAttribute('albumId');
    final coverArt = element.getAttribute('coverArt') ?? albumId;

    return Song(
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
      // Try multiple possible ReplayGain attribute names that Navidrome might use
      replayGainTrackGain:
          double.tryParse(element.getAttribute('replayGainTrackGain') ?? '') ??
              double.tryParse(element.getAttribute('rgTrackGain') ?? '') ??
              double.tryParse(element.getAttribute('trackGain') ?? ''),
      replayGainAlbumGain:
          double.tryParse(element.getAttribute('replayGainAlbumGain') ?? '') ??
              double.tryParse(element.getAttribute('rgAlbumGain') ?? '') ??
              double.tryParse(element.getAttribute('albumGain') ?? ''),
      replayGainTrackPeak:
          double.tryParse(element.getAttribute('replayGainTrackPeak') ?? '') ??
              double.tryParse(element.getAttribute('rgTrackPeak') ?? '') ??
              double.tryParse(element.getAttribute('trackPeak') ?? ''),
      replayGainAlbumPeak:
          double.tryParse(element.getAttribute('replayGainAlbumPeak') ?? '') ??
              double.tryParse(element.getAttribute('rgAlbumPeak') ?? '') ??
              double.tryParse(element.getAttribute('albumPeak') ?? ''),
    );
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
