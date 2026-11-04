class ReplayGainData {
  final double? trackGain;
  final double? albumGain;
  final double? trackPeak;
  final double? albumPeak;

  const ReplayGainData({
    this.trackGain,
    this.albumGain,
    this.trackPeak,
    this.albumPeak,
  });

  bool get hasAnyData =>
      trackGain != null ||
      albumGain != null ||
      trackPeak != null ||
      albumPeak != null;

  @override
  String toString() {
    return 'ReplayGainData(trackGain: $trackGain, albumGain: $albumGain, trackPeak: $trackPeak, albumPeak: $albumPeak)';
  }
}
