import 'audio_cache.dart';
import 'replaygain_debug_logger.dart';
import 'replaygain_reader.dart';
import 'settings_service.dart';
import 'subsonic_api.dart';

/// Where a song's ReplayGain data comes from, and the gain it plays at. See
/// docs/REPLAYGAIN.md.
class ReplayGainResolver {
  final SettingsService _settings;
  final AudioCache _audioCache;
  final SubsonicApi _api;

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
  /// file: from the audio cache if it's downloaded, else from the start of
  /// the file on the server. Null if the song has data already, or it can't
  /// be read (logged, not thrown: the song then plays at the fallback gain).
  Future<ReplayGainData?> readMissing(Song song) async {
    logReplayGain(
      () =>
          '[ReplayGain] Processing song: "${song.title}" by "${song.artist}" '
          '(id=${song.id}, album="${song.album}", format=${song.suffix}/${song.contentType})',
    );
    if (song.replayGainTrackGain != null || song.replayGainAlbumGain != null) {
      return null;
    }

    logReplayGain(
      () => '[ReplayGain] No ReplayGain in API response, reading from file...',
    );
    try {
      final data =
          await _audioCache.readReplayGain(song) ??
          await _api.readReplayGain(song.id);
      logReplayGain(
        () =>
            '[ReplayGain] File reading complete: '
            'TrackGain=${data.trackGain?.toStringAsFixed(2) ?? "null"}, '
            'AlbumGain=${data.albumGain?.toStringAsFixed(2) ?? "null"}, '
            'TrackPeak=${data.trackPeak?.toStringAsFixed(4) ?? "null"}, '
            'AlbumPeak=${data.albumPeak?.toStringAsFixed(4) ?? "null"}',
      );
      return data;
    } catch (e, stackTrace) {
      logReplayGain(() => '[ReplayGain] ERROR reading ReplayGain metadata: $e');
      logReplayGain(() => '[ReplayGain] Stack trace: $stackTrace');
      return null;
    }
  }

  /// Writes how the gain of [song] came about to the ReplayGain debug log.
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
