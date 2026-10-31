import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'fake_server_certificate.dart';

/// A song on the [FakeSubsonicServer]. Its audio is a generated tone of
/// [length].
class FakeSong {
  final String id;
  final String title;
  final Duration length;

  const FakeSong(this.id, this.title,
      {this.length = const Duration(seconds: 4)});
}

class FakeAlbum {
  final String id;
  final String name;
  final String artist;
  final List<FakeSong> songs;

  const FakeAlbum(this.id, this.name, this.artist, this.songs);

  String get artistId => 'ar-${artist.toLowerCase().replaceAll(' ', '-')}';
}

/// A request the server answered: the endpoint (`getAlbum`, `stream`, ...)
/// and its query parameters, auth parameters included.
class FakeRequest {
  final String endpoint;
  final Map<String, String> params;

  const FakeRequest(this.endpoint, this.params);

  @override
  String toString() => '$endpoint $params';
}

/// A scrobble the server received: a "now playing" or a play.
class FakeScrobble {
  final String songId;
  final bool submission;
  final DateTime? time;

  const FakeScrobble(this.songId, {required this.submission, this.time});

  @override
  String toString() => '${submission ? 'play' : 'now playing'} $songId';
}

/// A Subsonic server over HTTPS on localhost for tests, answering like
/// Navidrome: XML responses, errors as HTTP 200 with `status="failed"`,
/// token authentication, range requests for `stream`.
///
/// Runs on the host (`flutter test`) and inside the app on a device
/// (integration tests). Clients must trust its self-signed certificate,
/// see [httpOverrides]; debug builds of the Android app trust it for
/// localhost, so the native player streams from it too. See
/// tool/fake_server_cert.sh.
///
/// Endpoints: ping, getAlbumList2, getAlbum, getArtists, getArtist, search3,
/// getRandomSongs, getScanStatus, scrobble, stream (a WAV tone per song),
/// getCoverArt (a PNG).
class FakeSubsonicServer {
  FakeSubsonicServer({
    this.username = 'alice',
    this.password = 'secret',
    List<FakeAlbum>? albums,
  }) : albums = albums ?? defaultAlbums;

  /// Three albums of two or three songs, four seconds each
  static const defaultAlbums = [
    FakeAlbum('al-1', 'First Light', 'Aurora Test', [
      FakeSong('s-1', 'Dawn'),
      FakeSong('s-2', 'Noon'),
      FakeSong('s-3', 'Dusk'),
    ]),
    FakeAlbum('al-2', 'Second Wind', 'Breeze Band', [
      FakeSong('s-4', 'Gust'),
      FakeSong('s-5', 'Calm'),
    ]),
    FakeAlbum('al-3', 'Third Rail', 'Aurora Test', [
      FakeSong('s-6', 'Spark'),
      FakeSong('s-7', 'Current'),
    ]),
  ];

  final String username;

  /// The password the server accepts. Change it to simulate a password
  /// changed on the server.
  String password;

  final List<FakeAlbum> albums;

  /// Every request answered, oldest first
  final List<FakeRequest> requests = [];

  /// Every scrobble received, oldest first
  final List<FakeScrobble> scrobbles = [];

  HttpServer? _server;
  final _random = Random(1);

  /// Trusts the server's certificate in every [HttpClient] created while
  /// set as [HttpOverrides.global]. Other certificates aren't trusted.
  static HttpOverrides get httpOverrides => _TrustFakeServer();

  int get port => _server!.port;

  /// The URL to log in with
  String get url => 'https://localhost:$port';

  Future<void> start() async {
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(fakeServerCertificate))
      ..usePrivateKeyBytes(utf8.encode(fakeServerPrivateKey));
    _server =
        await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    _server!.listen((request) => unawaited(_handle(request)));
  }

  Future<void> close() async => _server?.close(force: true);

  Iterable<FakeSong> get _songs => albums.expand((album) => album.songs);

  FakeAlbum? _albumOf(String songId) {
    for (final album in albums) {
      if (album.songs.any((song) => song.id == songId)) return album;
    }
    return null;
  }

  /// The requests to [endpoint] so far
  List<FakeRequest> requestsTo(String endpoint) => [
        for (final r in requests)
          if (r.endpoint == endpoint) r
      ];

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      var endpoint =
          segments.length == 2 && segments[0] == 'rest' ? segments[1] : '';
      if (endpoint.endsWith('.view')) {
        endpoint = endpoint.substring(0, endpoint.length - 5);
      }
      final params = request.uri.queryParameters;
      requests.add(FakeRequest(endpoint, params));

      if (!_authenticated(params)) {
        return _xmlError(response, 40, 'Wrong username or password');
      }
      switch (endpoint) {
        case 'ping':
          return _xml(response, '');
        case 'getAlbumList2':
          return _albumList(response, params);
        case 'getAlbum':
          return _album(response, params['id']);
        case 'getArtists':
          return _artists(response);
        case 'getArtist':
          return _artist(response, params['id']);
        case 'search3':
          return _search(response, params['query'] ?? '');
        case 'getRandomSongs':
          final size = int.tryParse(params['size'] ?? '') ?? 10;
          final songs = _songs.toList()..shuffle(_random);
          return _xml(response,
              '<randomSongs>${songs.take(size).map(_songXml).join()}</randomSongs>');
        case 'getScanStatus':
          return _xml(response,
              '<scanStatus scanning="false" count="${_songs.length}" lastScan="2026-01-01T00:00:00Z"/>');
        case 'scrobble':
          return _scrobble(response, params);
        case 'stream':
          return _stream(request, params['id']);
        case 'getCoverArt':
          response.headers.contentType = ContentType('image', 'png');
          response.add(_coverPng);
          return;
        default:
          return _xmlError(response, 0, 'Unknown endpoint: $endpoint');
      }
    } catch (e) {
      response.statusCode = HttpStatus.internalServerError;
      response.write('$e');
    } finally {
      await response.close();
    }
  }

  bool _authenticated(Map<String, String> params) {
    if (params['u'] != username) return false;
    final salt = params['s'];
    final token = params['t'];
    if (salt == null || token == null) return false;
    return md5.convert(utf8.encode(password + salt)).toString() == token;
  }

  void _xml(HttpResponse response, String body) {
    response.headers.contentType = ContentType('application', 'xml');
    response.write('<?xml version="1.0" encoding="UTF-8"?>'
        '<subsonic-response xmlns="http://subsonic.org/restapi" status="ok" version="1.16.1" type="navidrome" serverVersion="fake" openSubsonic="true">'
        '$body</subsonic-response>');
  }

  void _xmlError(HttpResponse response, int code, String message) {
    response.headers.contentType = ContentType('application', 'xml');
    response.write('<?xml version="1.0" encoding="UTF-8"?>'
        '<subsonic-response xmlns="http://subsonic.org/restapi" status="failed" version="1.16.1" type="navidrome" serverVersion="fake" openSubsonic="true">'
        '<error code="$code" message="${_escape(message)}"/></subsonic-response>');
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  String _albumAttributes(FakeAlbum album) {
    final duration =
        album.songs.fold(0, (sum, song) => sum + song.length.inSeconds);
    return 'id="${album.id}" name="${_escape(album.name)}" '
        'artist="${_escape(album.artist)}" artistId="${album.artistId}" '
        'coverArt="${album.id}" songCount="${album.songs.length}" '
        'duration="$duration" created="2026-01-01T00:00:00Z"';
  }

  String _songXml(FakeSong song) {
    final album = _albumOf(song.id)!;
    final track = album.songs.indexOf(song) + 1;
    return '<song id="${song.id}" parent="${album.id}" isDir="false" '
        'title="${_escape(song.title)}" album="${_escape(album.name)}" '
        'artist="${_escape(album.artist)}" track="$track" '
        'coverArt="${album.id}" albumId="${album.id}" '
        'artistId="${album.artistId}" duration="${song.length.inSeconds}" '
        'contentType="audio/wav" suffix="wav" type="music"/>';
  }

  void _albumList(HttpResponse response, Map<String, String> params) {
    final offset = int.tryParse(params['offset'] ?? '') ?? 0;
    final size = int.tryParse(params['size'] ?? '') ?? 10;
    final list = albums.skip(offset).take(size);
    _xml(response,
        '<albumList2>${list.map((a) => '<album ${_albumAttributes(a)}/>').join()}</albumList2>');
  }

  void _album(HttpResponse response, String? id) {
    final album = albums.where((a) => a.id == id).firstOrNull;
    if (album == null) return _xmlError(response, 70, 'Album not found');
    _xml(response,
        '<album ${_albumAttributes(album)}>${album.songs.map(_songXml).join()}</album>');
  }

  Map<String, List<FakeAlbum>> get _albumsByArtist {
    final byArtist = <String, List<FakeAlbum>>{};
    for (final album in albums) {
      byArtist.putIfAbsent(album.artist, () => []).add(album);
    }
    return byArtist;
  }

  void _artists(HttpResponse response) {
    final entries = _albumsByArtist.entries.map((e) =>
        '<index name="${e.key[0]}"><artist id="${e.value.first.artistId}" '
        'name="${_escape(e.key)}" albumCount="${e.value.length}"/></index>');
    _xml(response, '<artists>${entries.join()}</artists>');
  }

  void _artist(HttpResponse response, String? id) {
    final entry = _albumsByArtist.entries
        .where((e) => e.value.first.artistId == id)
        .firstOrNull;
    if (entry == null) return _xmlError(response, 70, 'Artist not found');
    _xml(
        response,
        '<artist id="$id" name="${_escape(entry.key)}" albumCount="${entry.value.length}">'
        '${entry.value.map((a) => '<album ${_albumAttributes(a)}/>').join()}</artist>');
  }

  void _search(HttpResponse response, String query) {
    final q = query.replaceAll('"', '').toLowerCase();
    bool matches(String s) => s.toLowerCase().contains(q);
    final artists = _albumsByArtist.entries.where((e) => matches(e.key)).map((e) =>
        '<artist id="${e.value.first.artistId}" name="${_escape(e.key)}" albumCount="${e.value.length}"/>');
    final found = albums
        .where((a) => matches(a.name))
        .map((a) => '<album ${_albumAttributes(a)}/>');
    final songs = _songs.where((s) => matches(s.title)).map(_songXml);
    _xml(response,
        '<searchResult3>${artists.join()}${found.join()}${songs.join()}</searchResult3>');
  }

  void _scrobble(HttpResponse response, Map<String, String> params) {
    final id = params['id'];
    if (id == null || _albumOf(id) == null) {
      return _xmlError(response, 70, 'Song not found');
    }
    final time = int.tryParse(params['time'] ?? '');
    scrobbles.add(FakeScrobble(id,
        submission: params['submission'] != 'false',
        time: time == null ? null : DateTime.fromMillisecondsSinceEpoch(time)));
    _xml(response, '');
  }

  final Map<String, Uint8List> _audio = {};

  /// Serves the song's WAV, honoring a `Range: bytes=start-[end]` header
  void _stream(HttpRequest request, String? id) {
    final response = request.response;
    final song = _songs.where((s) => s.id == id).firstOrNull;
    if (song == null) return _xmlError(response, 70, 'Song not found');
    final bytes = _audio[song.id] ??=
        _wav(song.length, 220.0 + 110 * _songs.toList().indexOf(song));

    response.headers.contentType = ContentType('audio', 'wav');
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    final range = RegExp(r'^bytes=(\d+)-(\d*)$')
        .firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
    var start = 0;
    var end = bytes.length - 1;
    if (range != null) {
      start = int.parse(range[1]!);
      if (range[2]!.isNotEmpty) end = min(int.parse(range[2]!), end);
      if (start > end) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes */${bytes.length}');
        return;
      }
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
          HttpHeaders.contentRangeHeader, 'bytes $start-$end/${bytes.length}');
    }
    response.contentLength = end - start + 1;
    if (request.method != 'HEAD') {
      response.add(Uint8List.sublistView(bytes, start, end + 1));
    }
  }

  /// A quiet sine tone of [length] at [frequency] Hz: 16-bit mono WAV at
  /// 22050 Hz
  static Uint8List _wav(Duration length, double frequency) {
    const rate = 22050;
    final samples = rate * length.inMilliseconds ~/ 1000;
    final data = ByteData(44 + samples * 2);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + samples * 2, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, 1, Endian.little); // mono
    data.setUint32(24, rate, Endian.little);
    data.setUint32(28, rate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, samples * 2, Endian.little);
    for (var i = 0; i < samples; i++) {
      final value = (sin(2 * pi * frequency * i / rate) * 3000).round();
      data.setInt16(44 + i * 2, value, Endian.little);
    }
    return data.buffer.asUint8List();
  }

  /// A 2x2 purple PNG
  static final _coverPng = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGNIM54JRAwQCgAg'
      'ugTJFh6ueAAAAABJRU5ErkJggg==');
}

class _TrustFakeServer extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(utf8.encode(fakeServerCa)));
}
