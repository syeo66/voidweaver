import 'package:logging/logging.dart';

import 'audio_cache.dart';
import 'replaygain/replaygain_log.dart';
import 'replaygain_reader.dart';
import 'settings_service.dart';
import 'subsonic_api.dart';

final _log = Logger('replaygain');

/// Where a song's ReplayGain data comes from, and the gain it plays at. See
/// docs/REPLAYGAIN.md.
class ReplayGainResolver {
  final SettingsService _settings;
  final AudioCache _audioCache;
  final SubsonicApi _api;

  // Songs whose file was read and has no ReplayGain tags. Not read again:
  // a start or skip waits for the read, up to a few seconds over the network
  // (see ReplayGainReader.readFromUrl), every time the song plays. One per
  // login, as the resolver is; ids are the server's.
  final Set<String> _untagged = {};

  ReplayGainResolver(this._settings, this._audioCache, this._api);

  /// The linear gain [song] plays at, from its ReplayGain data and the
  /// settings. Smart mode uses the album gain when the queue is an album
  /// ([fromAlbum]).
  double gainFor(Song song, {required bool fromAlbum}) =>
      _settings.calculateVolumeAdjustment(
        trackGain: song.replayGainTrackGain,
        albumGain: song.replayGainAlbumGain,
        trackPeak: song.replayGainTrackPeak,
        albumPeak: song.replayGainAlbumPeak,
        fromAlbum: fromAlbum,
      );

  /// ReplayGain data for a [song] the server sent none for, read from its
  /// file: from the audio cache if its start is cached and holds the whole
  /// tag, else from the start of the file on the server. Null if the song has
  /// data already, or the read threw; [ReplayGainData.unavailable] if the
  /// file couldn't be read (offline, a timeout). Failures are logged, not
  /// thrown: the song then plays at the fallback gain.
  ///
  /// A file that was read and has no tags isn't read again; one that couldn't
  /// be read is.
  Future<ReplayGainData?> readMissing(Song song) async {
    logReplayGain(
      () =>
          '[ReplayGain] Processing song: "${song.title}" by "${song.artist}" '
          '(id=${song.id}, album="${song.album}", format=${song.suffix}/${song.contentType})',
    );
    if (song.replayGainTrackGain != null || song.replayGainAlbumGain != null) {
      return null;
    }
    if (_untagged.contains(song.id)) {
      logReplayGain(
        () =>
            '[ReplayGain] No ReplayGain in API response or file (read before)',
      );
      return const ReplayGainData();
    }

    logReplayGain(
      () => '[ReplayGain] No ReplayGain in API response, reading from file...',
    );
    try {
      final cached = await _audioCache.readReplayGain(song);
      // Unavailable: only part of the tag is cached (a track partly played),
      // which the server has in full
      final data = cached == null || cached.unavailable
          ? await _api.readReplayGain(song.id)
          : cached;
      logReplayGain(
        () =>
            '[ReplayGain] File reading complete: '
            'TrackGain=${data.trackGain?.toStringAsFixed(2) ?? "null"}, '
            'AlbumGain=${data.albumGain?.toStringAsFixed(2) ?? "null"}, '
            'TrackPeak=${data.trackPeak?.toStringAsFixed(4) ?? "null"}, '
            'AlbumPeak=${data.albumPeak?.toStringAsFixed(4) ?? "null"}'
            '${data.unavailable ? ' (could not be read)' : ''}',
      );
      if (!data.hasAnyData && !data.unavailable) _untagged.add(song.id);
      return data;
    } catch (e, stack) {
      // The reads return unavailable data for the failures they expect
      // (network, storage), so this points to a bug
      _log.warning('Could not read ReplayGain of song ${song.id}', e, stack);
      return null;
    }
  }

  /// Logs how the gain of [song] came about, for the session log.
  /// [queue] names what the queue was started from.
  void logTrack(Song song, {required bool fromAlbum, required String queue}) {
    if (!replayGainLogging) return;
    for (final line in trackGainReport(
      song,
      _settings,
      gain: gainFor(song, fromAlbum: fromAlbum),
      queue: queue,
    )) {
      logReplayGain(() => line);
    }
  }
}
