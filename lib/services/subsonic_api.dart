import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

class SubsonicApi {
  final String serverUrl;
  final String username;
  final String password;
  final String clientName = 'voidweaver';
  final String version = '1.16.1';

  SubsonicApi({
    required this.serverUrl,
    required this.username,
    required this.password,
  });

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

  Future<XmlDocument> _makeRequest(String endpoint, [Map<String, String>? extraParams]) async {
    final params = _getAuthParams();
    if (extraParams != null) {
      params.addAll(extraParams);
    }

    final uri = Uri.parse('$serverUrl/rest/$endpoint').replace(queryParameters: params);
    
    try {
      final headers = {
        'Content-Type': 'application/xml',
        'User-Agent': 'voidweaver/1.0',
      };
      
      final response = await http.get(uri, headers: headers);
      
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
    final doc = await _makeRequest('getAlbumList2', {'type': 'recent', 'size': '500'});
    final albums = <Album>[];
    
    final albumElements = doc.findAllElements('album');
    for (final element in albumElements) {
      albums.add(Album.fromXml(element));
    }
    
    return albums;
  }

  Future<Album> getAlbum(String id) async {
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
  }

  Future<List<Song>> getRandomSongs([int count = 50]) async {
    final doc = await _makeRequest('getRandomSongs', {'size': count.toString()});
    final songs = <Song>[];
    
    final songElements = doc.findAllElements('song');
    for (final element in songElements) {
      songs.add(Song.fromXml(element));
    }
    
    return songs;
  }

  String getStreamUrl(String id) {
    final params = _getAuthParams();
    params['id'] = id;
    
    final uri = Uri.parse('$serverUrl/rest/stream').replace(queryParameters: params);
    return uri.toString();
  }

  String getCoverArtUrl(String id) {
    final params = _getAuthParams();
    params['id'] = id;
    params['size'] = '300';
    
    final uri = Uri.parse('$serverUrl/rest/getCoverArt').replace(queryParameters: params);
    return uri.toString();
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
      replayGainTrackGain: double.tryParse(element.getAttribute('replayGainTrackGain') ?? '') ??
                          double.tryParse(element.getAttribute('rgTrackGain') ?? '') ??
                          double.tryParse(element.getAttribute('trackGain') ?? ''),
      replayGainAlbumGain: double.tryParse(element.getAttribute('replayGainAlbumGain') ?? '') ??
                          double.tryParse(element.getAttribute('rgAlbumGain') ?? '') ??
                          double.tryParse(element.getAttribute('albumGain') ?? ''),
      replayGainTrackPeak: double.tryParse(element.getAttribute('replayGainTrackPeak') ?? '') ??
                          double.tryParse(element.getAttribute('rgTrackPeak') ?? '') ??
                          double.tryParse(element.getAttribute('trackPeak') ?? ''),
      replayGainAlbumPeak: double.tryParse(element.getAttribute('replayGainAlbumPeak') ?? '') ??
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