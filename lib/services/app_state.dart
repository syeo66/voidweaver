import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'subsonic_api.dart';
import 'audio_player_service.dart';
import 'audio_cache.dart';
import 'image_cache_manager.dart';
import 'settings_service.dart';
import 'playback_persistence.dart';
import 'replaygain_debug_logger.dart';
import 'scrobble_queue.dart';

enum SyncStatus {
  idle,
  syncing,
  success,
  error,
}

enum LoadingState {
  idle,
  loading,
  success,
  error,
}

class AppState extends ChangeNotifier {
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  // Legacy credential keys in SharedPreferences, see _migrateFromSharedPreferences
  static const _legacyCredentialKeys = ['server_url', 'username', 'password'];

  SubsonicApi? _api;
  AudioPlayerService? _audioPlayerService;
  AudioCache? _audioCache;
  ScrobbleQueue? _scrobbleQueue;
  SettingsService? _settingsService;
  PlaybackPersistenceService? _persistenceService;
  List<Album> _albums = [];
  bool _isLoading = false;
  String? _error;
  bool _isConfigured = false;
  SyncStatus _syncStatus = SyncStatus.idle;
  Timer? _syncTimer;
  Timer? _syncStatusResetTimer;
  DateTime? _lastSyncTime;

  // Enhanced loading states
  LoadingState _configurationLoadingState = LoadingState.idle;
  LoadingState _albumLoadingState = LoadingState.idle;
  String? _configurationError;
  String? _albumError;

  SubsonicApi? get api => _api;
  AudioPlayerService? get audioPlayerService => _audioPlayerService;
  SettingsService? get settingsService => _settingsService;
  List<Album> get albums => _albums;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isConfigured => _isConfigured;
  SyncStatus get syncStatus => _syncStatus;
  DateTime? get lastSyncTime => _lastSyncTime;

  // Enhanced loading state getters
  LoadingState get configurationLoadingState => _configurationLoadingState;
  LoadingState get albumLoadingState => _albumLoadingState;
  String? get configurationError => _configurationError;
  String? get albumError => _albumError;

  Future<void> initialize() async {
    _settingsService = SettingsService();
    await _settingsService!.initialize();

    await ReplayGainDebugLogger.instance.initialize();

    _persistenceService = PlaybackPersistenceService();
    await _persistenceService!.initialize();

    await _loadServerConfig();
  }

  /// Sets up the services for a server. With [verifyCredentials] (a new
  /// login) the server is pinged first, so an unreachable server or wrong
  /// credentials fail here. Saved credentials aren't checked, so the app
  /// still starts offline.
  Future<void> configure(String serverUrl, String username, String password,
      {bool verifyCredentials = false}) async {
    _configurationLoadingState = LoadingState.loading;
    _configurationError = null;
    notifyListeners();

    // In case an earlier attempt failed after creating its services
    _disposeServices();

    try {
      final api = SubsonicApi(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );
      if (verifyCredentials) {
        try {
          await api.ping();
        } catch (_) {
          api.dispose();
          rethrow;
        }
      }
      _api = api;

      _audioCache = AudioCache(namespace: serverUrl);
      _scrobbleQueue = ScrobbleQueue(api);
      _audioPlayerService = AudioPlayerService(
        api,
        _settingsService!,
        persistence: _persistenceService,
        audioCache: _audioCache,
        scrobbleQueue: _scrobbleQueue,
      );

      _isConfigured = true;
      _configurationLoadingState = LoadingState.success;

      await _saveServerConfig(serverUrl, username, password);

      // Attempt to restore previous playback state
      try {
        final restored = await _audioPlayerService!.restorePlaybackState();
        if (restored) {
          debugPrint('Successfully restored previous playback state');
        }
      } catch (e) {
        debugPrint('Failed to restore playback state: $e');
        // Continue normally if restoration fails
      }

      await loadAlbums();
      _startBackgroundSync();
      notifyListeners();
    } catch (e) {
      _configurationError = e.toString();
      _error = e.toString();
      _configurationLoadingState = LoadingState.error;
      _isConfigured = false;
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
  }

  /// Removes downloaded audio, cached library data and cover art.
  Future<void> clearCaches() async {
    await Future.wait([
      if (_audioPlayerService != null) _audioPlayerService!.clearAudioCache(),
      if (_api != null) _api!.clearCache(),
      ImageCacheManager.clearCache(),
    ]);
  }

  Future<void> loadAlbums() async {
    if (_api == null) return;

    _isLoading = true;
    _albumLoadingState = LoadingState.loading;
    _error = null;
    _albumError = null;
    notifyListeners();

    try {
      _albums = await _api!.getAlbumList();
      _albumLoadingState = LoadingState.success;
    } catch (e) {
      _error = e.toString();
      _albumError = e.toString();
      _albumLoadingState = LoadingState.error;
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

    // Reset success to idle after 3 seconds; errors persist until the next sync
    _syncStatusResetTimer?.cancel();
    _syncStatusResetTimer = Timer(const Duration(seconds: 3), () {
      if (_syncStatus == SyncStatus.success) {
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
    _syncStatusResetTimer?.cancel();
    _syncStatusResetTimer = null;
  }

  /// Releases the services of the current login. Disposing the player ends
  /// its media session, which removes the notification.
  void _disposeServices() {
    _stopBackgroundSync();
    _audioPlayerService?.dispose();
    _audioPlayerService = null;
    // Already disposed by the player; kept to clear it on logout
    _scrobbleQueue = null;
    _audioCache?.dispose();
    _audioCache = null;
    _api?.dispose();
    _api = null;
  }

  Future<void> _saveServerConfig(
      String serverUrl, String username, String password) async {
    try {
      await _secureStorage.write(key: 'server_url', value: serverUrl);
      await _secureStorage.write(key: 'username', value: username);
      await _secureStorage.write(key: 'password', value: password);
    } catch (e) {
      debugPrint('Error saving secure credentials: $e');
      rethrow;
    }
  }

  Future<void> _loadServerConfig() async {
    try {
      final serverUrl = await _secureStorage.read(key: 'server_url');
      final username = await _secureStorage.read(key: 'username');
      final password = await _secureStorage.read(key: 'password');

      if (serverUrl != null && username != null && password != null) {
        await configure(serverUrl, username, password);
      }
    } catch (e) {
      debugPrint('Error loading secure credentials: $e');
      // Fallback to check old SharedPreferences for migration
      await _migrateFromSharedPreferences();
    }
  }

  /// Logs out: releases the services and removes the credentials and the
  /// data that belongs to the server (library cache, pending scrobbles, saved
  /// queue). Settings are kept.
  Future<void> clearConfiguration() async {
    final api = _api;
    final scrobbleQueue = _scrobbleQueue;
    // Dispose first, so nothing writes the server's data again afterwards
    _disposeServices();

    try {
      await _secureStorage.deleteAll();
      await Future.wait([
        if (api != null) api.clearCache(),
        if (scrobbleQueue != null) scrobbleQueue.clear(),
        if (_persistenceService != null)
          _persistenceService!.clearPlaybackState(),
      ]);

      final prefs = await SharedPreferences.getInstance();
      for (final key in _legacyCredentialKeys) {
        await prefs.remove(key);
      }
    } catch (e) {
      debugPrint('Error clearing configuration: $e');
    }

    _albums.clear();
    _isConfigured = false;
    _error = null;
    _syncStatus = SyncStatus.idle;
    _lastSyncTime = null;

    // Reset loading states
    _configurationLoadingState = LoadingState.idle;
    _albumLoadingState = LoadingState.idle;
    _configurationError = null;
    _albumError = null;

    notifyListeners();
  }

  /// Migrates credentials from old SharedPreferences to secure storage
  Future<void> _migrateFromSharedPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final serverUrl = prefs.getString('server_url');
      final username = prefs.getString('username');
      final password = prefs.getString('password');

      if (serverUrl != null && username != null && password != null) {
        debugPrint(
            'Migrating credentials from SharedPreferences to secure storage');

        // Save to secure storage
        await _saveServerConfig(serverUrl, username, password);

        // Remove from SharedPreferences
        for (final key in _legacyCredentialKeys) {
          await prefs.remove(key);
        }

        // Configure with migrated credentials
        await configure(serverUrl, username, password);

        debugPrint('Credential migration completed successfully');
      }
    } catch (e) {
      debugPrint('Error during credential migration: $e');
    }
  }

  @override
  void dispose() {
    _disposeServices();
    _persistenceService?.dispose();
    super.dispose();
  }
}
