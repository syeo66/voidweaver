import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/app_state.dart';
import '../services/audio_player_service.dart';
import '../services/subsonic_api.dart';
import '../widgets/album_list.dart';
import '../widgets/player_controls.dart';
import '../widgets/sync_status_indicator.dart';
import '../widgets/error_boundary.dart';
import 'settings_screen.dart';
import 'search_screen.dart';
import 'artist_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  bool _isPlayingRandomSongs = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voidweaver'),
        actions: [
          const SyncStatusIndicator(),
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const SearchScreen()),
              );
            },
          ),
          IconButton(
            icon: _isPlayingRandomSongs
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.shuffle),
            onPressed: _isPlayingRandomSongs
                ? null
                : () async {
                    setState(() => _isPlayingRandomSongs = true);

                    final appState = context.read<AppState>();
                    final messenger = ScaffoldMessenger.of(context);

                    try {
                      await appState.audioPlayerService?.playRandomSongs();
                    } catch (e) {
                      if (mounted) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text('Failed to play random songs: $e'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    } finally {
                      if (mounted) {
                        setState(() => _isPlayingRandomSongs = false);
                      }
                    }
                  },
          ),
          Consumer<AppState>(
            builder: (context, appState, child) {
              if (appState.audioPlayerService == null ||
                  !appState.isConfigured) {
                return const SizedBox(width: 0, height: 0);
              }
              return ListenableBuilder(
                listenable: appState.audioPlayerService!,
                builder: (context, child) {
                  return IconButton(
                    icon: appState.audioPlayerService!.isSleepTimerActive
                        ? const Icon(Icons.bedtime, color: Colors.orange)
                        : const Icon(Icons.bedtime_outlined),
                    onPressed: () => _showSleepTimerDialog(
                        context, appState.audioPlayerService!),
                  );
                },
              );
            },
          ),
          PopupMenuButton(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'logout') {
                context.read<AppState>().clearConfiguration();
              } else if (value == 'settings') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (context) => const SettingsScreen()),
                );
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings),
                    SizedBox(width: 8),
                    Text('Settings'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout),
                    SizedBox(width: 8),
                    Text('Logout'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: IndexedStack(
              index: _currentIndex,
              children: [
                const AlbumList().withErrorBoundary(
                  errorMessage: 'Failed to load albums. Please try refreshing.',
                ),
                const ArtistScreen().withErrorBoundary(
                  errorMessage:
                      'Failed to load artists. Please try refreshing.',
                ),
                ErrorBoundary(
                  errorMessage: 'Failed to load now playing screen.',
                  child: _buildNowPlayingScreen(),
                ),
              ],
            ),
          ),
          Consumer<AppState>(
            builder: (context, appState, child) {
              if (appState.audioPlayerService == null) {
                return const SizedBox.shrink();
              }
              return ChangeNotifierProvider.value(
                value: appState.audioPlayerService!,
                child: const PlayerControls().withErrorBoundary(
                  errorMessage: 'Player controls encountered an error.',
                ),
              );
            },
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.library_music),
            label: 'Albums',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: 'Artists',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.music_note),
            label: 'Now Playing',
          ),
        ],
      ),
    );
  }

  Widget _buildNowPlayingScreen() {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        if (appState.audioPlayerService == null) {
          return const Center(child: Text('No audio player available'));
        }

        return ChangeNotifierProvider.value(
          value: appState.audioPlayerService!,
          child: _NowPlayingContent(appState: appState),
        );
      },
    );
  }

  void _showSleepTimerDialog(
      BuildContext context, AudioPlayerService playerService) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return _SleepTimerDialog(playerService: playerService);
      },
    );
  }
}

class _StaticPlaylistInfo extends StatefulWidget {
  final AudioPlayerService playerService;
  final SubsonicApi api;
  final bool isCompact;

  const _StaticPlaylistInfo({
    required this.playerService,
    required this.api,
    this.isCompact = false,
  });

  @override
  State<_StaticPlaylistInfo> createState() => _StaticPlaylistInfoState();
}

class _StaticPlaylistInfoState extends State<_StaticPlaylistInfo> {
  List<Song> _currentPlaylist = [];
  int _currentIndex = 0;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _currentPlaylist = widget.playerService.playlist;
    _currentIndex = widget.playerService.currentIndex;
    widget.playerService.addListener(_onPlayerServiceChanged);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    widget.playerService.removeListener(_onPlayerServiceChanged);
    super.dispose();
  }

  void _onPlayerServiceChanged() {
    // Only rebuild if the playlist or current index changed
    final newPlaylist = widget.playerService.playlist;
    final newCurrentIndex = widget.playerService.currentIndex;

    if (newPlaylist != _currentPlaylist || newCurrentIndex != _currentIndex) {
      final shouldAutoScroll = newCurrentIndex != _currentIndex;

      setState(() {
        _currentPlaylist = newPlaylist;
        _currentIndex = newCurrentIndex;
      });

      // Auto-scroll to the current track after the widget rebuilds
      if (shouldAutoScroll && _currentPlaylist.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToCurrentTrack();
        });
      }
    }
  }

  void _scrollToCurrentTrack() {
    if (!_scrollController.hasClients || _currentPlaylist.isEmpty) return;

    // Calculate the scroll position to center the current track
    // Item width depends on compact mode
    final double itemWidth =
        widget.isCompact ? 60.0 + 8.0 : 80.0 + 8.0; // width + margin
    final double targetPosition = _currentIndex * itemWidth;

    // Get the viewport width to center the item
    final double viewportWidth = _scrollController.position.viewportDimension;
    final double centeredPosition =
        targetPosition - (viewportWidth / 2) + (itemWidth / 2);

    // Ensure we don't scroll beyond the bounds
    final double maxScrollExtent = _scrollController.position.maxScrollExtent;
    final double clampedPosition = centeredPosition.clamp(0.0, maxScrollExtent);

    _scrollController.animateTo(
      clampedPosition,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_currentPlaylist.isEmpty) return const SizedBox.shrink();

    if (widget.isCompact) {
      // Compact mode for landscape - smaller height and items
      return Column(
        children: [
          Text(
            'Playlist: ${_currentIndex + 1} of ${_currentPlaylist.length}',
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 60,
            child: ListView.builder(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              itemCount: _currentPlaylist.length,
              itemBuilder: (context, index) {
                final song = _currentPlaylist[index];
                final isCurrentSong = index == _currentIndex;

                return _PlaylistItem(
                  key: ValueKey('playlist-item-${song.id}'),
                  song: song,
                  isCurrentSong: isCurrentSong,
                  api: widget.api,
                  isCompact: true,
                );
              },
            ),
          ),
        ],
      );
    }

    // Full mode for portrait
    return Column(
      children: [
        const Divider(),
        Text(
          'Playlist: ${_currentIndex + 1} of ${_currentPlaylist.length}',
          style: TextStyle(color: Colors.grey[600]),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 100,
          child: ListView.builder(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            itemCount: _currentPlaylist.length,
            itemBuilder: (context, index) {
              final song = _currentPlaylist[index];
              final isCurrentSong = index == _currentIndex;

              return _PlaylistItem(
                key: ValueKey('playlist-item-${song.id}'),
                song: song,
                isCurrentSong: isCurrentSong,
                api: widget.api,
                isCompact: false,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PlaylistItem extends StatelessWidget {
  final Song song;
  final bool isCurrentSong;
  final SubsonicApi api;
  final bool isCompact;

  const _PlaylistItem({
    super.key,
    required this.song,
    required this.isCurrentSong,
    required this.api,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    final itemSize = isCompact ? 40.0 : 60.0;
    final containerWidth = isCompact ? 60.0 : 80.0;
    final fontSize = isCompact ? 8.0 : 10.0;
    final iconSize = isCompact ? 16.0 : 24.0;

    return Container(
      width: containerWidth,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        children: [
          Container(
            width: itemSize,
            height: itemSize,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(isCompact ? 6 : 8),
              color: isCurrentSong
                  ? Theme.of(context).primaryColor.withValues(alpha: 0.1)
                  : Colors.grey[300],
              border: isCurrentSong
                  ? Border.all(
                      color: Theme.of(context).primaryColor,
                      width: isCompact ? 2 : 3)
                  : null,
              boxShadow: isCurrentSong
                  ? [
                      BoxShadow(
                        color: Theme.of(context)
                            .primaryColor
                            .withValues(alpha: 0.3),
                        blurRadius: isCompact ? 4 : 8,
                        spreadRadius: isCompact ? 0.5 : 1,
                      )
                    ]
                  : null,
            ),
            child: Stack(
              children: [
                song.coverArt != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(isCompact ? 6 : 8),
                        child: CachedNetworkImage(
                          imageUrl: api.getCoverArtUrl(song.coverArt!),
                          key: ValueKey('playlist-${song.id}-${song.coverArt}'),
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Icon(
                            Icons.music_note,
                            color: isCurrentSong ? Colors.white : Colors.grey,
                            size: iconSize * 0.8,
                          ),
                          errorWidget: (context, url, error) => Icon(
                            Icons.music_note,
                            color: isCurrentSong ? Colors.white : Colors.grey,
                            size: iconSize * 0.8,
                          ),
                        ),
                      )
                    : Icon(
                        Icons.music_note,
                        color: isCurrentSong ? Colors.white : Colors.grey,
                        size: iconSize * 0.8,
                      ),
                if (isCurrentSong)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(isCompact ? 6 : 8),
                        color: Colors.black.withValues(alpha: 0.3),
                      ),
                      child: Icon(
                        Icons.play_arrow,
                        color: Colors.white,
                        size: iconSize,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (!isCompact) ...[
            const SizedBox(height: 4),
            Text(
              song.title,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: isCurrentSong ? FontWeight.bold : FontWeight.normal,
                color: isCurrentSong ? Theme.of(context).primaryColor : null,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}

class _NowPlayingContent extends StatelessWidget {
  final AppState appState;

  const _NowPlayingContent({required this.appState});

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Consumer<AudioPlayerService>(
      builder: (context, playerService, child) {
        final currentSong = playerService.currentSong;

        if (currentSong == null) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.music_off, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text('No song playing',
                    style: TextStyle(fontSize: 18, color: Colors.grey)),
              ],
            ),
          );
        }

        // Return child that contains static widgets
        return child!;
      },
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: isLandscape ? _buildLandscapeLayout() : _buildPortraitLayout(),
      ),
    );
  }

  Widget _buildPortraitLayout() {
    return Column(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _StaticAlbumArt(
                  playerService: appState.audioPlayerService!,
                  api: appState.api!),
              const SizedBox(height: 24),
              _StaticSongInfo(playerService: appState.audioPlayerService!),
            ],
          ),
        ),
        _StaticPlaylistInfo(
            playerService: appState.audioPlayerService!, api: appState.api!),
      ],
    );
  }

  Widget _buildLandscapeLayout() {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              // Left side: Album art
              Expanded(
                flex: 1,
                child: Center(
                  child: _StaticAlbumArt(
                    playerService: appState.audioPlayerService!,
                    api: appState.api!,
                  ),
                ),
              ),
              const SizedBox(width: 24),
              // Right side: Song info and controls
              Expanded(
                flex: 1,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _StaticSongInfo(
                        playerService: appState.audioPlayerService!),
                    const SizedBox(height: 24),
                    // Compact playlist in landscape
                    Flexible(
                      child: _StaticPlaylistInfo(
                        playerService: appState.audioPlayerService!,
                        api: appState.api!,
                        isCompact: true,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StaticAlbumArt extends StatefulWidget {
  final AudioPlayerService playerService;
  final SubsonicApi api;

  const _StaticAlbumArt({
    required this.playerService,
    required this.api,
  });

  @override
  State<_StaticAlbumArt> createState() => _StaticAlbumArtState();
}

class _StaticAlbumArtState extends State<_StaticAlbumArt> {
  Song? _currentSong;
  String? _currentCoverArtUrl;
  Widget? _cachedImageWidget;

  @override
  void initState() {
    super.initState();
    _currentSong = widget.playerService.currentSong;
    _updateCoverArtUrl();
    widget.playerService.addListener(_onPlayerServiceChanged);
  }

  @override
  void dispose() {
    widget.playerService.removeListener(_onPlayerServiceChanged);
    super.dispose();
  }

  void _updateCoverArtUrl() {
    final newUrl = _currentSong?.coverArt != null
        ? widget.api.getCoverArtUrl(_currentSong!.coverArt!)
        : null;

    if (newUrl != _currentCoverArtUrl) {
      _currentCoverArtUrl = newUrl;
      _cachedImageWidget = null; // Clear cache when URL changes
    }
  }

  void _onPlayerServiceChanged() {
    final newSong = widget.playerService.currentSong;

    // Update the display when the song actually changes
    final songChanged = newSong?.id != _currentSong?.id;

    if (songChanged) {
      setState(() {
        _currentSong = newSong;
        _updateCoverArtUrl();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_currentSong == null) {
      return Container(
        width: 200,
        height: 200,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Colors.grey[300],
        ),
        child: const Icon(Icons.music_note, size: 64, color: Colors.grey),
      );
    }

    return Container(
      width: 200,
      height: 200,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.grey[300],
      ),
      child: _currentCoverArtUrl != null
          ? _buildCachedImage()
          : const Icon(Icons.music_note, size: 64, color: Colors.grey),
    );
  }

  Widget _buildCachedImage() {
    if (_cachedImageWidget != null) {
      return _cachedImageWidget!;
    }

    _cachedImageWidget = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: CachedNetworkImage(
        imageUrl: _currentCoverArtUrl!,
        key: ValueKey('main-$_currentCoverArtUrl'),
        fit: BoxFit.cover,
        placeholder: (context, url) => Container(
          color: Colors.grey[300],
          child: const Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
            ),
          ),
        ),
        errorWidget: (context, url, error) =>
            const Icon(Icons.music_note, size: 64, color: Colors.grey),
      ),
    );

    return _cachedImageWidget!;
  }
}

class _StaticSongInfo extends StatelessWidget {
  final AudioPlayerService playerService;

  const _StaticSongInfo({
    required this.playerService,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<AudioPlayerService>(
      builder: (context, playerService, child) {
        final currentSong = playerService.currentSong;

        if (currentSong == null) {
          return const SizedBox.shrink();
        }

        return Column(
          children: [
            Text(
              currentSong.title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              currentSong.artist,
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              currentSong.album,
              style: TextStyle(fontSize: 14, color: Colors.grey[500]),
              textAlign: TextAlign.center,
            ),
          ],
        );
      },
    );
  }
}

class _SleepTimerDialog extends StatefulWidget {
  final AudioPlayerService playerService;

  const _SleepTimerDialog({required this.playerService});

  @override
  State<_SleepTimerDialog> createState() => _SleepTimerDialogState();
}

class _SleepTimerDialogState extends State<_SleepTimerDialog> {
  static const List<Duration> _presetDurations = [
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(minutes: 45),
    Duration(minutes: 60),
    Duration(minutes: 90),
    Duration(minutes: 120),
  ];

  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    // Update remaining time every second
    _updateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Sleep Timer'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.playerService.isSleepTimerActive) ...[
            const Text('Timer Active'),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: Column(
                children: [
                  const Icon(Icons.bedtime, color: Colors.orange, size: 32),
                  const SizedBox(height: 8),
                  Text(
                    'Time remaining:',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                  Text(
                    widget.playerService.sleepTimerRemaining != null
                        ? _formatDuration(
                            widget.playerService.sleepTimerRemaining!)
                        : '00:00',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.orange,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('+15m'),
                  onPressed: () {
                    widget.playerService
                        .extendSleepTimer(const Duration(minutes: 15));
                  },
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.cancel),
                  label: const Text('Cancel'),
                  onPressed: () {
                    widget.playerService.cancelSleepTimer();
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ),
          ] else ...[
            const Text('Set sleep timer duration:'),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _presetDurations.map((duration) {
                return ElevatedButton(
                  onPressed: () {
                    widget.playerService.startSleepTimer(duration);
                    Navigator.of(context).pop();
                  },
                  child: Text(_formatDuration(duration)),
                );
              }).toList(),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;

    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else {
      return '${minutes}m';
    }
  }
}
