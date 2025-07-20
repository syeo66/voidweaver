import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:audio_service/audio_service.dart';
import 'subsonic_api.dart';
import 'audio_player_service.dart';
import 'audio_handler.dart';
import 'settings_service.dart';

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
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  SubsonicApi? _api;
  AudioPlayerService? _audioPlayerService;
  SettingsService? _settingsService;
  VoidweaverAudioHandler? _audioHandler;
  List<Album> _albums = [];
  bool _isLoading = false;
  String? _error;
  bool _isConfigured = false;
  bool _audioServiceInitialized = false;
  SyncStatus _syncStatus = SyncStatus.idle;
  Timer? _syncTimer;
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
    await _loadServerConfig();
  }

  Future<void> configure(
      String serverUrl, String username, String password) async {
    _configurationLoadingState = LoadingState.loading;
    _configurationError = null;
    notifyListeners();

    try {
      _api = SubsonicApi(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );

      _audioPlayerService = AudioPlayerService(_api!, _settingsService!);

      // Initialize audio service for native controls
      await _initializeAudioService();

      _isConfigured = true;
      _configurationLoadingState = LoadingState.success;

      await _saveServerConfig(serverUrl, username, password);
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

  Future<void> _initializeAudioService() async {
    if (_audioPlayerService == null || _audioServiceInitialized) return;

    try {
      _audioHandler = VoidweaverAudioHandler(_audioPlayerService!, _api!);
      await AudioService.init(
        builder: () => _audioHandler!,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.voidweaver.audio',
          androidNotificationChannelName: 'Voidweaver Audio',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
      _audioServiceInitialized = true;
      debugPrint('Audio service initialized successfully');
    } catch (e) {
      debugPrint('Error initializing audio service: $e');
      // Don't throw - app should still work without native controls
    }
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

  Future<void> clearConfiguration() async {
    try {
      await _secureStorage.deleteAll();

      // Also clear old SharedPreferences for complete cleanup
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } catch (e) {
      debugPrint('Error clearing secure credentials: $e');
    }

    _stopBackgroundSync();
    _api = null;
    _audioPlayerService?.dispose();
    _audioPlayerService = null;
    _audioHandler?.dispose();
    _audioHandler = null;
    _audioServiceInitialized = false;
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
        await prefs.remove('server_url');
        await prefs.remove('username');
        await prefs.remove('password');

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
    _stopBackgroundSync();
    super.dispose();
  }
}
