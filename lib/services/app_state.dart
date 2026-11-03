import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:voidweaver_player/voidweaver_player.dart' show MediaCache;
import 'subsonic_api.dart';
import '../models/album_list_type.dart';
import 'audio_player_service.dart';
import 'audio_cache.dart';
import 'image_cache_manager.dart';
import 'settings_service.dart';
import 'playback_persistence.dart';
import 'replaygain_debug_logger.dart';
import 'scrobble_queue.dart';
import 'network_config.dart';
import 'network_errors.dart';
import '../utils/validators.dart';

final _log = Logger('app_state');

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

  /// The secure storage key of the credentials: server URL, username and
  /// password in one JSON value, so they're always written together. A
  /// write that fails leaves the previous credentials, never a mix.
  @visibleForTesting
  static const credentialsKey = 'credentials';

  SubsonicApi? _api;
  AudioPlayerService? _audioPlayerService;
  AudioCache? _audioCache;
  ScrobbleQueue? _scrobbleQueue;
  SettingsService? _settingsService;
  PlaybackPersistenceService? _persistenceService;
  List<Album> _albums = [];
  // The album list's load: running, and why the last one failed
  bool _isLoading = false;
  String? _albumError;
  bool _isConfigured = false;
  SyncStatus _syncStatus = SyncStatus.idle;
  Timer? _syncTimer;
  Timer? _syncStatusResetTimer;
  DateTime? _lastSyncTime;

  static const _syncInterval = Duration(minutes: 5);
  // Background sync only runs while the app is visible, see setVisible()
  bool _visible = true;

  // What secure storage holds (server URL, username, password), as read at
  // startup or last written; configure() only writes credentials that differ
  (String, String, String)? _savedCredentials;

  // The timeouts last handed to the player, see _applyNetworkConfig()
  (Duration, Duration)? _playerTimeouts;

  // The login: its progress, and why it failed
  LoadingState _configurationLoadingState = LoadingState.idle;
  String? _configurationError;

  SubsonicApi? get api => _api;
  AudioPlayerService? get audioPlayerService => _audioPlayerService;
  SettingsService? get settingsService => _settingsService;
  List<Album> get albums => _albums;
  AlbumListType get albumListType =>
      _settingsService?.albumListType ?? AlbumListType.recent;

  /// Whether the album list is being loaded, see [loadAlbums]
  bool get isLoading => _isLoading;

  /// Why the last load of the album list failed; cleared by the next load
  /// or background sync that succeeds
  String? get albumError => _albumError;
  bool get isConfigured => _isConfigured;
  SyncStatus get syncStatus => _syncStatus;
  DateTime? get lastSyncTime => _lastSyncTime;

  /// Whether the server refused the saved credentials, e.g. because the
  /// password was changed on the server. [updatePassword] fixes it without
  /// logging out.
  bool get credentialsRejected => _api?.credentialsRejected.value ?? false;

  /// Plays not yet scrobbled to the server; a logout drops them
  int get pendingScrobbles => _scrobbleQueue?.pendingSubmissions ?? 0;

  /// The progress of [configure], for the login screen
  LoadingState get configurationLoadingState => _configurationLoadingState;

  /// Why the last [configure] failed, for the login screen
  String? get configurationError => _configurationError;

  Future<void> initialize() async {
    _settingsService = SettingsService();
    await _settingsService!.initialize();
    _settingsService!.addListener(_applyNetworkConfig);
    // Before anything streams
    _applyNetworkConfig();
    // The app's theme comes from the settings
    notifyListeners();

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
    serverUrl = Validators.normalizeServerUrl(serverUrl);
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
        networkConfig: _settingsService!.networkConfig,
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
      api.credentialsRejected.addListener(notifyListeners);

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

      // Not on every start: the writes delay a resume for a media button, and
      // one that failed would log out a user whose credentials are fine.
      if (_savedCredentials != (serverUrl, username, password)) {
        await _saveServerConfig(serverUrl, username, password);
      }
      _startBackgroundSync();
      notifyListeners();
    } catch (e) {
      // Saving the credentials can fail after the services were created;
      // release them (the player's media session among them)
      _disposeServices();
      _configurationError = NetworkErrorHelper.getErrorMessage(e);
      _configurationLoadingState = LoadingState.error;
      _isConfigured = false;
      // A load of the previous login's albums is dropped, see loadAlbums()
      _isLoading = false;
      notifyListeners();
      rethrow;
    }

    // Not awaited, as they can wait for the network (retries, timeouts):
    // the home screen shows right away and fills in
    unawaited(loadAlbums());
    unawaited(_restorePlayback(_audioPlayerService!));
  }

  /// Switches to a new [password] for the same server and user, for when
  /// the server rejected the saved one ([credentialsRejected]). Everything
  /// stays as it is: playback goes on, and the pending scrobbles are sent
  /// with the new password.
  ///
  /// Throws if the server doesn't accept [password] (or can't be reached),
  /// or it can't be saved; the current login stays as it is then.
  Future<void> updatePassword(String password) async {
    final current = _api;
    if (current == null) throw StateError('Not logged in');
    final check = SubsonicApi(
      serverUrl: current.serverUrl,
      username: current.username,
      password: password,
      networkConfig: _settingsService!.networkConfig,
    );
    try {
      await check.ping();
    } finally {
      check.dispose();
    }
    // Logged out or in again meanwhile
    if (!identical(current, _api)) return;
    // Saved first: if that fails, nothing has changed
    await _saveServerConfig(current.serverUrl, current.username, password);
    if (!identical(current, _api)) return;
    current.usePassword(password);
    _audioPlayerService?.credentialsChanged();
    // Rather than at the queue's next timer tick
    unawaited(_scrobbleQueue?.processQueue());
    notifyListeners();
  }

  /// Restores the queue saved by the last session, then plays it if a media
  /// button started the app. Stops if [player] was released meanwhile (a
  /// logout).
  Future<void> _restorePlayback(AudioPlayerService player) async {
    try {
      if (await player.restorePlaybackState()) {
        _log.info('Successfully restored previous playback state');
      }
      if (!identical(player, _audioPlayerService)) return;
      await player.resumeIfRequested();
    } catch (e) {
      _log.warning('Failed to restore playback state', e);
    }
  }

  /// Hands changed network settings to the API (timeouts, retries) and to
  /// the player, whose streaming and downloads use the connection and
  /// streaming timeouts. Called on every settings change.
  void _applyNetworkConfig() {
    final config = _settingsService!.networkConfig;
    _api?.networkConfig = config;
    _setPlayerTimeouts(config);
  }

  void _setPlayerTimeouts(NetworkConfig config) {
    final timeouts = (config.connectionTimeout, config.streamingTimeout);
    if (timeouts == _playerTimeouts) return;
    _playerTimeouts = timeouts;
    unawaited(const MediaCache()
        .setTimeouts(connect: timeouts.$1, read: timeouts.$2)
        .catchError((Object e) {
      _log.warning('Could not set the player\'s timeouts', e);
    }));
  }

  /// Removes downloaded audio, cached library data and cover art.
  Future<void> clearCaches() async {
    await Future.wait([
      if (_audioPlayerService != null) _audioPlayerService!.clearAudioCache(),
      if (_api != null) _api!.clearCache(),
      ImageCacheManager.clearCache(),
    ]);
  }

  /// Saves the order of the album list and loads it in that order
  Future<void> setAlbumListType(AlbumListType type) async {
    if (type == albumListType) return;
    await _settingsService!.setAlbumListType(type);
    // The spinner rather than the old list in the new order's place
    _albums = [];
    await loadAlbums();
  }

  /// Loads the album list. [forceRefresh] (a refresh by the user) bypasses
  /// the API cache's fresh entry; when offline the cached list is used.
  Future<void> loadAlbums({bool forceRefresh = false}) async {
    final api = _api;
    if (api == null) return;
    final type = albumListType;

    _isLoading = true;
    _albumError = null;
    notifyListeners();

    try {
      final albums =
          await api.getAlbumList(type: type, forceRefresh: forceRefresh);
      // Logged out or switched to the other order meanwhile, in which case
      // the load for that order finishes
      if (!identical(api, _api) || type != albumListType) return;
      _albums = albums;
      _lastSyncTime = DateTime.now();
    } catch (e) {
      if (!identical(api, _api) || type != albumListType) return;
      _albumError = NetworkErrorHelper.getErrorMessage(e,
          context: 'Failed to load albums');
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> _backgroundSync() async {
    final api = _api;
    if (api == null || _syncStatus == SyncStatus.syncing) return;

    _syncStatus = SyncStatus.syncing;
    notifyListeners();
    final type = albumListType;

    try {
      final newAlbums = await api.getAlbumList(type: type);
      // Logged out meanwhile
      if (!identical(api, _api)) return;
      // Switched to the other order meanwhile: that load's list, error and
      // time stay, see loadAlbums()
      if (type != albumListType) {
        _syncStatus = SyncStatus.idle;
        notifyListeners();
        return;
      }
      _albums = newAlbums;
      _syncStatus = SyncStatus.success;
      _lastSyncTime = DateTime.now();
      _albumError = null;
    } catch (e) {
      if (!identical(api, _api)) return;
      if (type != albumListType) {
        _syncStatus = SyncStatus.idle;
        notifyListeners();
        return;
      }
      // Only the sync indicator shows this; the albums loaded before stay
      _syncStatus = SyncStatus.error;
      _log.warning('Background sync failed', e);
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
    if (!_visible) return;
    _syncTimer = Timer.periodic(_syncInterval, (timer) {
      unawaited(_backgroundSync());
    });
  }

  /// Called when the app is shown or hidden. Background sync pauses while
  /// the app is hidden (e.g. playing with the screen off), so it doesn't wake
  /// the network for a list nobody sees; when shown again, a sync that came
  /// due meanwhile runs right away.
  void setVisible(bool visible) {
    if (visible == _visible) return;
    _visible = visible;
    if (_api == null) return;
    if (!visible) {
      _stopBackgroundSync();
      return;
    }
    _startBackgroundSync();
    final lastSync = _lastSyncTime;
    if (lastSync == null ||
        DateTime.now().difference(lastSync) >= _syncInterval) {
      unawaited(_backgroundSync());
    }
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
    _audioCache = null;
    _api?.dispose();
    _api = null;
  }

  Future<void> _saveServerConfig(
      String serverUrl, String username, String password) async {
    try {
      await _secureStorage.write(
          key: credentialsKey,
          value: jsonEncode({
            'serverUrl': serverUrl,
            'username': username,
            'password': password,
          }));
      _savedCredentials = (serverUrl, username, password);
    } catch (e) {
      // Unknown whether it was written
      _savedCredentials = null;
      _log.warning('Error saving secure credentials', e);
      rethrow;
    }
  }

  Future<void> _loadServerConfig() async {
    try {
      final saved = await _readSavedCredentials();
      if (saved != null) {
        _savedCredentials = saved;
        await configure(saved.$1, saved.$2, saved.$3);
      }
    } catch (e) {
      _log.warning('Error loading secure credentials', e);
    }
  }

  /// The credentials in secure storage, if any.
  Future<(String, String, String)?> _readSavedCredentials() async {
    final json = await _secureStorage.read(key: credentialsKey);
    if (json == null) return null;
    final map = jsonDecode(json) as Map<String, dynamic>;
    final serverUrl = map['serverUrl'] as String?;
    final username = map['username'] as String?;
    final password = map['password'] as String?;
    if (serverUrl == null || username == null || password == null) {
      return null;
    }
    return (serverUrl, username, password);
  }

  /// Logs out: releases the services and removes the credentials and the
  /// data that belongs to the server (library cache, cover art, pending
  /// scrobbles, saved queue). Settings are kept.
  Future<void> clearConfiguration() async {
    final api = _api;
    final scrobbleQueue = _scrobbleQueue;
    // Dispose first, so nothing writes the server's data again afterwards
    _disposeServices();

    _savedCredentials = null;
    // Each on its own, so one that fails doesn't leave the others' data
    Future<void> clear(String what, Future<void> Function() step) async {
      try {
        await step();
      } catch (e) {
        _log.warning('Logout could not clear $what', e);
      }
    }

    await Future.wait([
      clear('the credentials', _secureStorage.deleteAll),
      if (api != null) clear('the library cache', api.clearCache),
      if (scrobbleQueue != null)
        clear('the pending scrobbles', scrobbleQueue.clear),
      if (_persistenceService != null)
        clear('the saved queue', _persistenceService!.clearPlaybackState),
      clear('the cover art', ImageCacheManager.clearCache),
    ]);

    _albums = [];
    // A load still running is dropped, see loadAlbums()
    _isLoading = false;
    _albumError = null;
    _isConfigured = false;
    _syncStatus = SyncStatus.idle;
    _lastSyncTime = null;
    _configurationLoadingState = LoadingState.idle;
    _configurationError = null;

    notifyListeners();
  }

  @override
  void dispose() {
    _settingsService?.removeListener(_applyNetworkConfig);
    _disposeServices();
    _persistenceService?.dispose();
    super.dispose();
  }
}
