import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'subsonic_api.dart';
import 'audio_player_service.dart';
import 'settings_service.dart';

enum SyncStatus {
  idle,
  syncing,
  success,
  error,
}

class AppState extends ChangeNotifier {
  SubsonicApi? _api;
  AudioPlayerService? _audioPlayerService;
  SettingsService? _settingsService;
  List<Album> _albums = [];
  bool _isLoading = false;
  String? _error;
  bool _isConfigured = false;
  SyncStatus _syncStatus = SyncStatus.idle;
  Timer? _syncTimer;
  DateTime? _lastSyncTime;

  SubsonicApi? get api => _api;
  AudioPlayerService? get audioPlayerService => _audioPlayerService;
  SettingsService? get settingsService => _settingsService;
  List<Album> get albums => _albums;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isConfigured => _isConfigured;
  SyncStatus get syncStatus => _syncStatus;
  DateTime? get lastSyncTime => _lastSyncTime;

  Future<void> initialize() async {
    _settingsService = SettingsService();
    await _settingsService!.initialize();
    await _loadServerConfig();
  }

  Future<void> configure(String serverUrl, String username, String password) async {
    try {
      _api = SubsonicApi(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );
      
      _audioPlayerService = AudioPlayerService(_api!, _settingsService!);
      _isConfigured = true;
      
      await _saveServerConfig(serverUrl, username, password);
      await loadAlbums();
      _startBackgroundSync();
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      _isConfigured = false;
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> loadAlbums() async {
    if (_api == null) return;
    
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _albums = await _api!.getAlbumList();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _backgroundSync() async {
    if (_api == null || _syncStatus == SyncStatus.syncing) return;
    
    _syncStatus = SyncStatus.syncing;
    notifyListeners();

    try {
      final newAlbums = await _api!.getAlbumList();
      _albums = newAlbums;
      _syncStatus = SyncStatus.success;
      _lastSyncTime = DateTime.now();
      _error = null;
    } catch (e) {
      _syncStatus = SyncStatus.error;
      _error = e.toString();
    }
    
    notifyListeners();
    
    // Reset to idle after 3 seconds
    Timer(const Duration(seconds: 3), () {
      if (_syncStatus != SyncStatus.syncing) {
        _syncStatus = SyncStatus.idle;
        notifyListeners();
      }
    });
  }

  void _startBackgroundSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(minutes: 5), (timer) {
      _backgroundSync();
    });
  }

  void _stopBackgroundSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  Future<void> _saveServerConfig(String serverUrl, String username, String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', serverUrl);
    await prefs.setString('username', username);
    await prefs.setString('password', password);
  }

  Future<void> _loadServerConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final serverUrl = prefs.getString('server_url');
    final username = prefs.getString('username');
    final password = prefs.getString('password');

    if (serverUrl != null && username != null && password != null) {
      await configure(serverUrl, username, password);
    }
  }

  Future<void> clearConfiguration() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    
    _stopBackgroundSync();
    _api = null;
    _audioPlayerService?.dispose();
    _audioPlayerService = null;
    _albums.clear();
    _isConfigured = false;
    _error = null;
    _syncStatus = SyncStatus.idle;
    _lastSyncTime = null;
    
    notifyListeners();
  }

  @override
  void dispose() {
    _stopBackgroundSync();
    super.dispose();
  }
}