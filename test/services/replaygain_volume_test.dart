import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;

  double dbToLinear(double db) => math.pow(10.0, db / 20.0).toDouble();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService();
    addTearDown(settings.dispose);
    await settings.initialize();
  });

  group('mode', () {
    test('off leaves the volume alone', () async {
      await settings.setReplayGainMode(ReplayGainMode.off);
      await settings.setReplayGainPreamp(6);

      expect(
          settings.calculateVolumeAdjustment(
              trackGain: -8, albumGain: -6, trackPeak: 0.9, albumPeak: 0.9),
          1.0);
    });

    test('track uses the track gain', () async {
      await settings.setReplayGainMode(ReplayGainMode.track);

      expect(
          settings.calculateVolumeAdjustment(
              trackGain: -6, albumGain: -9, trackPeak: 0.5, albumPeak: 0.5),
          closeTo(dbToLinear(-6), 1e-9));
    });

    test('album uses the album gain', () async {
      await settings.setReplayGainMode(ReplayGainMode.album);

      expect(
          settings.calculateVolumeAdjustment(
              trackGain: -6, albumGain: -9, trackPeak: 0.5, albumPeak: 0.5),
          closeTo(dbToLinear(-9), 1e-9));
    });

    test('smart uses the album gain for an album', () async {
      await settings.setReplayGainMode(ReplayGainMode.smart);

      expect(
          settings.calculateVolumeAdjustment(
              trackGain: -6,
              albumGain: -9,
              trackPeak: 0.5,
              albumPeak: 0.5,
              fromAlbum: true),
          closeTo(dbToLinear(-9), 1e-9));
    });

    test('smart uses the track gain outside an album', () async {
      await settings.setReplayGainMode(ReplayGainMode.smart);

      expect(
          settings.calculateVolumeAdjustment(
              trackGain: -6, albumGain: -9, trackPeak: 0.5, albumPeak: 0.5),
          closeTo(dbToLinear(-6), 1e-9));
    });

    test('album falls back to the track gain', () async {
      await settings.setReplayGainMode(ReplayGainMode.album);

      expect(settings.calculateVolumeAdjustment(trackGain: -6, trackPeak: 0.5),
          closeTo(dbToLinear(-6), 1e-9));
    });
  });

  group('fallback gain', () {
    test('applies to a track without ReplayGain data', () async {
      await settings.setReplayGainMode(ReplayGainMode.track);
      await settings.setReplayGainFallbackGain(-3);

      expect(
          settings.calculateVolumeAdjustment(), closeTo(dbToLinear(-3), 1e-9));
    });

    test('applies in album mode without track or album gain', () async {
      await settings.setReplayGainMode(ReplayGainMode.album);
      await settings.setReplayGainFallbackGain(-3);

      expect(
          settings.calculateVolumeAdjustment(), closeTo(dbToLinear(-3), 1e-9));
    });

    test('is ignored when the track has a gain', () async {
      await settings.setReplayGainMode(ReplayGainMode.track);
      await settings.setReplayGainFallbackGain(-3);

      expect(settings.calculateVolumeAdjustment(trackGain: -6, trackPeak: 0.5),
          closeTo(dbToLinear(-6), 1e-9));
    });

    test('is clamped to ±15 dB', () async {
      await settings.setReplayGainFallbackGain(20);
      expect(settings.replayGainFallbackGain, 15);
      await settings.setReplayGainFallbackGain(-20);
      expect(settings.replayGainFallbackGain, -15);
    });
  });

  group('preamp', () {
    test('is added to the gain', () async {
      await settings.setReplayGainMode(ReplayGainMode.track);
      await settings.setReplayGainPreamp(2);

      expect(settings.calculateVolumeAdjustment(trackGain: -6, trackPeak: 0.5),
          closeTo(dbToLinear(-4), 1e-9));
    });

    test('is added to the fallback gain', () async {
      await settings.setReplayGainMode(ReplayGainMode.track);
      await settings.setReplayGainPreamp(-2);
      await settings.setReplayGainFallbackGain(-3);

      expect(
          settings.calculateVolumeAdjustment(), closeTo(dbToLinear(-5), 1e-9));
    });

    test('is clamped to ±15 dB', () async {
      await settings.setReplayGainPreamp(20);
      expect(settings.replayGainPreamp, 15);
      await settings.setReplayGainPreamp(-20);
      expect(settings.replayGainPreamp, -15);
    });
  });

  group('clipping prevention', () {
    setUp(() async {
      await settings.setReplayGainMode(ReplayGainMode.track);
    });

    test('is on by default', () {
      expect(settings.replayGainPreventClipping, isTrue);
    });

    test('lowers a gain that would push the peak above full scale', () {
      // +6 dB is about 2x, so a peak of 0.8 would reach 1.6
      expect(settings.calculateVolumeAdjustment(trackGain: 6, trackPeak: 0.8),
          closeTo(1 / 0.8, 1e-9));
    });

    test('keeps a positive gain that stays below full scale', () {
      expect(settings.calculateVolumeAdjustment(trackGain: 6, trackPeak: 0.4),
          closeTo(dbToLinear(6), 1e-9));
    });

    test('limits the preamp too', () async {
      await settings.setReplayGainPreamp(6);

      expect(settings.calculateVolumeAdjustment(trackGain: 0, trackPeak: 0.8),
          closeTo(1 / 0.8, 1e-9));
    });

    test('leaves a negative gain alone', () {
      expect(settings.calculateVolumeAdjustment(trackGain: -6, trackPeak: 1.2),
          closeTo(dbToLinear(-6), 1e-9));
    });

    test('assumes full scale without a peak, so no gain above 1', () {
      expect(settings.calculateVolumeAdjustment(trackGain: 6), 1.0);
    });

    test('uses the album peak in album mode', () async {
      await settings.setReplayGainMode(ReplayGainMode.album);

      expect(
          settings.calculateVolumeAdjustment(
              albumGain: 6, albumPeak: 0.9, trackPeak: 0.5),
          closeTo(1 / 0.9, 1e-9));
    });

    test('falls back to the track peak in album mode', () async {
      await settings.setReplayGainMode(ReplayGainMode.album);

      expect(settings.calculateVolumeAdjustment(albumGain: 6, trackPeak: 0.8),
          closeTo(1 / 0.8, 1e-9));
    });

    test('off lets the gain go above full scale', () async {
      await settings.setReplayGainPreventClipping(false);

      expect(settings.calculateVolumeAdjustment(trackGain: 6, trackPeak: 0.8),
          closeTo(dbToLinear(6), 1e-9));
      expect(settings.calculateVolumeAdjustment(trackGain: 6),
          closeTo(dbToLinear(6), 1e-9));
    });
  });

  test('settings survive a restart', () async {
    await settings.setReplayGainMode(ReplayGainMode.album);
    await settings.setReplayGainPreamp(3);
    await settings.setReplayGainPreventClipping(false);
    await settings.setReplayGainFallbackGain(-4);

    final restarted = SettingsService();
    addTearDown(restarted.dispose);
    await restarted.initialize();

    expect(restarted.replayGainMode, ReplayGainMode.album);
    expect(restarted.replayGainPreamp, 3);
    expect(restarted.replayGainPreventClipping, isFalse);
    expect(restarted.replayGainFallbackGain, -4);
    expect(restarted.calculateVolumeAdjustment(albumGain: -7),
        closeTo(dbToLinear(-4), 1e-9));
  });
}
