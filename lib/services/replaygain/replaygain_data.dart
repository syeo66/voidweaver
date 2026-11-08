class ReplayGainData {
  final double? trackGain;
  final double? albumGain;
  final double? trackPeak;
  final double? albumPeak;

  /// Whether the tags couldn't be read at all (offline, a timeout, the
  /// server refusing the file, a part of the file missing), as opposed to a
  /// file that was read and has no ReplayGain tags. Only the latter is known
  /// to have none, see `ReplayGainResolver.readMissing`.
  final bool unavailable;

  const ReplayGainData({
    this.trackGain,
    this.albumGain,
    this.trackPeak,
    this.albumPeak,
  }) : unavailable = false;

  /// No data, because the tags couldn't be read, see [unavailable]
  const ReplayGainData.unavailable()
    : trackGain = null,
      albumGain = null,
      trackPeak = null,
      albumPeak = null,
      unavailable = true;

  bool get hasAnyData =>
      trackGain != null ||
      albumGain != null ||
      trackPeak != null ||
      albumPeak != null;

  @override
  String toString() {
    if (unavailable) return 'ReplayGainData.unavailable()';
    return 'ReplayGainData(trackGain: $trackGain, albumGain: $albumGain, trackPeak: $trackPeak, albumPeak: $albumPeak)';
  }
}
