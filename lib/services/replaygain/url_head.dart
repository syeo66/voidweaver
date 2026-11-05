import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'reader_log.dart';

/// The start of the file at a URL, read only as far as asked, for
/// `ReplayGainReader.readFromHead`. Asks for each part with a Range request.
/// A server that ignores the Range header sends the whole file (200, e.g. a
/// transcoded stream): then later parts are read on from that same response,
/// and [close] stops the download by closing the connection.
class UrlHead {
  UrlHead(this._client, this._url);

  final http.Client _client;
  final String _url;
  final _bytes = BytesBuilder(copy: false);
  // The whole file, when the server ignored the Range header
  StreamIterator<List<int>>? _body;
  // Nothing more to read: the end of the file, an error or [close]
  bool _ended = false;

  /// Whether the server answered the first request with something other
  /// than the file: an error status, or a Subsonic error response (XML or
  /// JSON with HTTP 200, e.g. Navidrome's "downloads are disabled")
  bool refused = false;

  /// At least [length] bytes from the start of the file, or fewer if it
  /// ends sooner; null if nothing could be read.
  Future<Uint8List?> read(int length) async {
    while (!_ended && _bytes.length < length) {
      var body = _body;
      if (body == null) {
        final start = _bytes.length;
        final request = http.Request('GET', Uri.parse(_url))
          ..headers['Range'] = 'bytes=$start-${length - 1}';
        final response = await _client.send(request);
        if (_ended) {
          // Closed meanwhile
          await response.stream.listen(null).cancel();
          break;
        }
        if (start == 0 && _isSubsonicResponse(response)) {
          readerLog(
            () =>
                'Got a Subsonic response instead of audio: '
                '${response.headers['content-type']}',
          );
          await response.stream.listen(null).cancel();
          refused = true;
          _ended = true;
          break;
        }
        if (response.statusCode == 206) {
          await for (final chunk in response.stream) {
            _bytes.add(chunk);
            if (_bytes.length >= length) break;
          }
          // Less than asked for: the file ends here
          if (_bytes.length < length) _ended = true;
          continue;
        }
        if (response.statusCode != 200 || start > 0) {
          readerLog(() => 'Failed to fetch audio data: ${response.statusCode}');
          // Without reading the body
          await response.stream.listen(null).cancel();
          if (start == 0) refused = true;
          _ended = true;
          break;
        }
        readerLog(
          () =>
              'Server ignored the Range header, reading the start of the file',
        );
        body = _body = StreamIterator(response.stream);
      }
      if (await body.moveNext()) {
        _bytes.add(body.current);
      } else {
        _ended = true;
      }
    }
    return _bytes.isEmpty ? null : _bytes.toBytes();
  }

  static bool _isSubsonicResponse(http.StreamedResponse response) {
    final type = response.headers['content-type']?.toLowerCase() ?? '';
    return type.contains('xml') || type.contains('json');
  }

  /// Stops reading, also a read in progress
  Future<void> close() async {
    _ended = true;
    await _body?.cancel();
  }
}
