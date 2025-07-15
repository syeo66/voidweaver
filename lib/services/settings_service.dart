import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReplayGainMode {
  off,
  track,
  album,
}

class SettingsService extends ChangeNotifier {
  static const String _replayGainModeKey = 'replayGainMode';
  static const String _replayGainPreampKey = 'replayGainPreamp';
  static const String _replayGainPreventClippingKey = 'replayGainPreventClipping';
  static const String _replayGainFallbackGainKey = 'replayGainFallbackGain';

  SharedPreferences? _prefs;
  
  ReplayGainMode _replayGainMode = ReplayGainMode.off;
  double _replayGainPreamp = 0.0; // dB
  bool _replayGainPreventClipping = true;
  double _replayGainFallbackGain = 0.0; // dB for files without ReplayGain data

  ReplayGainMode get replayGainMode => _replayGainMode;
  double get replayGainPreamp => _replayGainPreamp;
  bool get replayGainPreventClipping => _replayGainPreventClipping;
  double get replayGainFallbackGain => _replayGainFallbackGain;

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadSettings();
  }

  Future<void> _loadSettings() async {
    if (_prefs == null) return;

    final modeIndex = _prefs!.getInt(_replayGainModeKey) ?? 0;
    _replayGainMode = ReplayGainMode.values[modeIndex];
    
    _replayGainPreamp = _prefs!.getDouble(_replayGainPreampKey) ?? 0.0;
    _replayGainPreventClipping = _prefs!.getBool(_replayGainPreventClippingKey) ?? true;
    _replayGainFallbackGain = _prefs!.getDouble(_replayGainFallbackGainKey) ?? 0.0;
    
    notifyListeners();
  }

  Future<void> setReplayGainMode(ReplayGainMode mode) async {
    _replayGainMode = mode;
    await _prefs?.setInt(_replayGainModeKey, mode.index);
    notifyListeners();
  }

  Future<void> setReplayGainPreamp(double preamp) async {
    _replayGainPreamp = preamp.clamp(-15.0, 15.0);
    await _prefs?.setDouble(_replayGainPreampKey, _replayGainPreamp);
    notifyListeners();
  }

  Future<void> setReplayGainPreventClipping(bool prevent) async {
    _replayGainPreventClipping = prevent;
    await _prefs?.setBool(_replayGainPreventClippingKey, prevent);
    notifyListeners();
  }

  Future<void> setReplayGainFallbackGain(double gain) async {
    _replayGainFallbackGain = gain.clamp(-15.0, 15.0);
    await _prefs?.setDouble(_replayGainFallbackGainKey, _replayGainFallbackGain);
    notifyListeners();
  }

  double calculateVolumeAdjustment({
    double? trackGain,
    double? albumGain,
    double? trackPeak,
    double? albumPeak,
  }) {
    if (_replayGainMode == ReplayGainMode.off) {
      return 1.0;
    }

    double gainToUse = 0.0;
    double peakToUse = 1.0;

    switch (_replayGainMode) {
      case ReplayGainMode.track:
        gainToUse = trackGain ?? _replayGainFallbackGain;
        peakToUse = trackPeak ?? 1.0;
        break;
      case ReplayGainMode.album:
        gainToUse = albumGain ?? trackGain ?? _replayGainFallbackGain;
        peakToUse = albumPeak ?? trackPeak ?? 1.0;
        break;
      case ReplayGainMode.off:
        return 1.0;
    }

    double totalGain = gainToUse + _replayGainPreamp;
    double volumeMultiplier = _dbToLinear(totalGain);

    if (_replayGainPreventClipping && peakToUse > 0) {
      double peakAfterGain = peakToUse * volumeMultiplier;
      if (peakAfterGain > 1.0) {
        volumeMultiplier = 1.0 / peakToUse;
      }
    }

    return volumeMultiplier.clamp(0.0, 1.0);
  }

  double _dbToLinear(double db) {
    return math.pow(10.0, db / 20.0).toDouble();
  }
}