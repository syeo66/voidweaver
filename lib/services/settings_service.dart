import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'network_config.dart';

enum ReplayGainMode {
  off,
  track,
  album,
}

class SettingsService extends ChangeNotifier {
  static const String _replayGainModeKey = 'replayGainMode';
  static const String _replayGainPreampKey = 'replayGainPreamp';
  static const String _replayGainPreventClippingKey =
      'replayGainPreventClipping';
  static const String _replayGainFallbackGainKey = 'replayGainFallbackGain';
  static const String _themeModeKey = 'themeMode';
  static const String _networkConfigKey = 'networkConfig';

  SharedPreferences? _prefs;

  ReplayGainMode _replayGainMode = ReplayGainMode.off;
  double _replayGainPreamp = 0.0; // dB
  bool _replayGainPreventClipping = true;
  double _replayGainFallbackGain = 0.0; // dB for files without ReplayGain data
  ThemeMode _themeMode = ThemeMode.system;
  NetworkConfig _networkConfig = NetworkConfig.defaultConfig;

  ReplayGainMode get replayGainMode => _replayGainMode;
  double get replayGainPreamp => _replayGainPreamp;
  bool get replayGainPreventClipping => _replayGainPreventClipping;
  double get replayGainFallbackGain => _replayGainFallbackGain;
  ThemeMode get themeMode => _themeMode;
  NetworkConfig get networkConfig => _networkConfig;

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadSettings();
  }

  Future<void> _loadSettings() async {
    if (_prefs == null) return;

    final modeIndex = _prefs!.getInt(_replayGainModeKey) ?? 0;
    _replayGainMode = ReplayGainMode.values[modeIndex];

    _replayGainPreamp = _prefs!.getDouble(_replayGainPreampKey) ?? 0.0;
    _replayGainPreventClipping =
        _prefs!.getBool(_replayGainPreventClippingKey) ?? true;
    _replayGainFallbackGain =
        _prefs!.getDouble(_replayGainFallbackGainKey) ?? 0.0;

    final themeModeIndex = _prefs!.getInt(_themeModeKey) ?? 0;
    _themeMode = ThemeMode.values[themeModeIndex];

    // Load network configuration
    final networkConfigJson = _prefs!.getString(_networkConfigKey);
    if (networkConfigJson != null) {
      try {
        final configMap = jsonDecode(networkConfigJson) as Map<String, dynamic>;
        _networkConfig = NetworkConfig.fromJson(configMap);
      } catch (e) {
        // If loading fails, use default config
        _networkConfig = NetworkConfig.defaultConfig;
      }
    } else {
      _networkConfig = NetworkConfig.defaultConfig;
    }

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
    await _prefs?.setDouble(
        _replayGainFallbackGainKey, _replayGainFallbackGain);
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

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await _prefs?.setInt(_themeModeKey, mode.index);
    notifyListeners();
  }

  /// Set network configuration
  Future<void> setNetworkConfig(NetworkConfig config) async {
    _networkConfig = config;
    final configJson = jsonEncode(config.toJson());
    await _prefs?.setString(_networkConfigKey, configJson);
    notifyListeners();
  }

  /// Set network configuration to default
  Future<void> resetNetworkConfigToDefault() async {
    await setNetworkConfig(NetworkConfig.defaultConfig);
  }

  /// Set network configuration to fast preset
  Future<void> setNetworkConfigToFast() async {
    await setNetworkConfig(NetworkConfig.fastConfig);
  }

  /// Set network configuration to slow preset
  Future<void> setNetworkConfigToSlow() async {
    await setNetworkConfig(NetworkConfig.slowConfig);
  }

  /// Update specific timeout values while keeping other settings
  Future<void> updateTimeouts({
    Duration? connectionTimeout,
    Duration? requestTimeout,
    Duration? metadataTimeout,
    Duration? streamingTimeout,
  }) async {
    final updatedConfig = _networkConfig.copyWith(
      connectionTimeout: connectionTimeout,
      requestTimeout: requestTimeout,
      metadataTimeout: metadataTimeout,
      streamingTimeout: streamingTimeout,
    );
    await setNetworkConfig(updatedConfig);
  }

  /// Update retry settings while keeping other settings
  Future<void> updateRetrySettings({
    int? maxRetryAttempts,
    Duration? initialRetryDelay,
    double? retryBackoffMultiplier,
    Duration? maxRetryDelay,
    bool? enableRetryOnTimeout,
    bool? enableRetryOnConnectionError,
  }) async {
    final updatedConfig = _networkConfig.copyWith(
      maxRetryAttempts: maxRetryAttempts,
      initialRetryDelay: initialRetryDelay,
      retryBackoffMultiplier: retryBackoffMultiplier,
      maxRetryDelay: maxRetryDelay,
      enableRetryOnTimeout: enableRetryOnTimeout,
      enableRetryOnConnectionError: enableRetryOnConnectionError,
    );
    await setNetworkConfig(updatedConfig);
  }
}
