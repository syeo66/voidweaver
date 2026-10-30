import 'package:logging/logging.dart';
import 'package:xml/xml.dart';

import '../services/replaygain_debug_logger.dart';

final _log = Logger('subsonic_api');
final _rgLogger = Logger('replaygain');

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

/// Whether ReplayGain parsing is logged: when the `replaygain` logger prints
/// `FINE` (debug builds, see setUpLogging()), or when the user has enabled
/// the ReplayGain debug log in Settings. Parsing runs for every
/// song, so the messages aren't even built otherwise.
bool get _rgLogging =>
    _rgLogger.isLoggable(Level.FINE) || ReplayGainDebugLogger.instance.enabled;

/// Logs to the console (debug builds, see setUpLogging()) and the persistent
/// ReplayGain debug log (only when the user has enabled it in Settings).
void _rgLog(String message) {
  _rgLogger.fine(message);
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
    final nested = element.findElements('replayGain').firstOrNull;

    // [name] on the nested element first, then as an attribute of the song
    // element for other servers (replayGainTrackGain, rgTrackGain, trackGain)
    double? replayGain(String name) {
      final suffix = name[0].toUpperCase() + name.substring(1);
      final candidates = [
        nested?.getAttribute(name),
        element.getAttribute('replayGain$suffix'),
        element.getAttribute('rg$suffix'),
        element.getAttribute(name),
      ];
      for (final value in candidates) {
        final parsed = double.tryParse(value ?? '');
        if (parsed != null) return parsed;
      }
      return null;
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
      replayGainTrackGain: replayGain('trackGain'),
      replayGainAlbumGain: replayGain('albumGain'),
      replayGainTrackPeak: replayGain('trackPeak'),
      replayGainAlbumPeak: replayGain('albumPeak'),
    );

    if (_rgLogging) {
      _rgLog('[ReplayGain XML] "${song.title}" (id=${song.id}), '
          '${nested != null ? 'nested <replayGain>' : 'song attributes'}: '
          'trackGain=${song.replayGainTrackGain}, albumGain=${song.replayGainAlbumGain}, '
          'trackPeak=${song.replayGainTrackPeak}, albumPeak=${song.replayGainAlbumPeak}');
    }

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
      if (_rgLogging) {
        _rgLog(
            '[ReplayGain JSON] "${json['title']}" (id=${json['id']}): nested replayGain='
            '{trackGain: $trackGain, albumGain: $albumGain, trackPeak: $trackPeak, albumPeak: $albumPeak}');
      }
    } else {
      // Fallback to flat format for backwards compatibility
      trackGain = (json['replayGainTrackGain'] as num?)?.toDouble();
      albumGain = (json['replayGainAlbumGain'] as num?)?.toDouble();
      trackPeak = (json['replayGainTrackPeak'] as num?)?.toDouble();
      albumPeak = (json['replayGainAlbumPeak'] as num?)?.toDouble();
      if (_rgLogging) {
        _rgLog(
            '[ReplayGain JSON] "${json['title']}" (id=${json['id']}): flat fields='
            '{trackGain: $trackGain, albumGain: $albumGain, trackPeak: $trackPeak, albumPeak: $albumPeak}');
      }
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
      for (final element in artistElements) {
        artists.add(Artist.fromXml(element));
      }

      final albumElements = searchResult.findAllElements('album');
      for (final element in albumElements) {
        albums.add(Album.fromXml(element));
      }

      final songElements = searchResult.findAllElements('song');
      for (final element in songElements) {
        songs.add(Song.fromXml(element));
      }
    } else {
      _log.fine(() =>
          'No searchResult3 element, found: ${doc.findAllElements('*').map((e) => e.name.local).toList()}');
    }

    final result = SearchResult(
      artists: artists,
      albums: albums,
      songs: songs,
    );

    _log.fine(
        'SearchResult created: ${artists.length} artists, ${albums.length} albums, ${songs.length} songs');

    return result;
  }

  bool get isEmpty => artists.isEmpty && albums.isEmpty && songs.isEmpty;
  bool get isNotEmpty => !isEmpty;
}
