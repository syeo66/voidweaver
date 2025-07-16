import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/app_state.dart';
import '../services/audio_player_service.dart';
import '../services/subsonic_api.dart';
import '../widgets/album_list.dart';
import '../widgets/player_controls.dart';
import '../widgets/sync_status_indicator.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voidweaver'),
        actions: [
          const SyncStatusIndicator(),
          IconButton(
            icon: const Icon(Icons.shuffle),
            onPressed: () async {
              final appState = context.read<AppState>();
              await appState.audioPlayerService?.playRandomSongs();
            },
          ),
          PopupMenuButton(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'logout') {
                context.read<AppState>().clearConfiguration();
              } else if (value == 'settings') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => const SettingsScreen()),
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
                const AlbumList(),
                _buildNowPlayingScreen(),
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
                child: const PlayerControls(),
              );
            },
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
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



}

class _StaticPlaylistInfo extends StatefulWidget {
  final AudioPlayerService playerService;
  final SubsonicApi api;

  const _StaticPlaylistInfo({
    required this.playerService,
    required this.api,
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
    // Each item is 80 pixels wide (including margin)
    const double itemWidth = 80.0 + 8.0; // width + margin
    final double targetPosition = _currentIndex * itemWidth;
    
    // Get the viewport width to center the item
    final double viewportWidth = _scrollController.position.viewportDimension;
    final double centeredPosition = targetPosition - (viewportWidth / 2) + (itemWidth / 2);
    
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

  const _PlaylistItem({
    super.key,
    required this.song,
    required this.isCurrentSong,
    required this.api,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 80,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: isCurrentSong ? Theme.of(context).primaryColor.withValues(alpha: 0.1) : Colors.grey[300],
              border: isCurrentSong ? Border.all(color: Theme.of(context).primaryColor, width: 3) : null,
              boxShadow: isCurrentSong ? [
                BoxShadow(
                  color: Theme.of(context).primaryColor.withValues(alpha: 0.3),
                  blurRadius: 8,
                  spreadRadius: 1,
                )
              ] : null,
            ),
            child: Stack(
              children: [
                song.coverArt != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CachedNetworkImage(
                          imageUrl: api.getCoverArtUrl(song.coverArt!),
                          key: ValueKey('playlist-${song.id}-${song.coverArt}'),
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Icon(
                            Icons.music_note,
                            color: isCurrentSong ? Colors.white : Colors.grey,
                          ),
                          errorWidget: (context, url, error) => Icon(
                            Icons.music_note,
                            color: isCurrentSong ? Colors.white : Colors.grey,
                          ),
                        ),
                      )
                    : Icon(
                        Icons.music_note,
                        color: isCurrentSong ? Colors.white : Colors.grey,
                      ),
                if (isCurrentSong)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: Colors.black.withValues(alpha: 0.3),
                      ),
                      child: const Icon(
                        Icons.play_arrow,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            song.title,
            style: TextStyle(
              fontSize: 10,
              fontWeight: isCurrentSong ? FontWeight.bold : FontWeight.normal,
              color: isCurrentSong ? Theme.of(context).primaryColor : null,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
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
                Text('No song playing', style: TextStyle(fontSize: 18, color: Colors.grey)),
              ],
            ),
          );
        }
        
        // Return child that contains static widgets
        return child!;
      },
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _StaticAlbumArt(playerService: appState.audioPlayerService!, api: appState.api!),
                  const SizedBox(height: 24),
                  _StaticSongInfo(playerService: appState.audioPlayerService!),
                ],
              ),
            ),
            _StaticPlaylistInfo(playerService: appState.audioPlayerService!, api: appState.api!),
          ],
        ),
      ),
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
        errorWidget: (context, url, error) => const Icon(Icons.music_note, size: 64, color: Colors.grey),
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