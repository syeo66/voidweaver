import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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

class _StaticPlaylistInfo extends StatelessWidget {
  final AudioPlayerService playerService;
  final SubsonicApi api;

  const _StaticPlaylistInfo({
    required this.playerService,
    required this.api,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<AudioPlayerService>(
      builder: (context, playerService, child) {
        final currentPlaylist = playerService.playlist;
        final currentIndex = playerService.currentIndex;

        if (currentPlaylist.isEmpty) return const SizedBox.shrink();
        
        return Column(
          children: [
            const Divider(),
            Text(
              'Playlist: ${currentIndex + 1} of ${currentPlaylist.length}',
              style: TextStyle(color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 100,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: currentPlaylist.length,
                itemBuilder: (context, index) {
                  final song = currentPlaylist[index];
                  final isCurrentSong = index == currentIndex;
                  
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
                            color: Colors.grey[300],
                            border: isCurrentSong ? Border.all(color: Theme.of(context).primaryColor, width: 2) : null,
                          ),
                          child: song.coverArt != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(
                                    api.getCoverArtUrl(song.coverArt!),
                                    key: ValueKey('playlist-${song.id}-${song.coverArt}'),
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) {
                                      return Icon(
                                        Icons.music_note,
                                        color: isCurrentSong ? Colors.white : Colors.grey,
                                      );
                                    },
                                  ),
                                )
                              : Icon(
                                  Icons.music_note,
                                  color: isCurrentSong ? Colors.white : Colors.grey,
                                ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          song.title,
                          style: const TextStyle(fontSize: 10),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
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

class _StaticAlbumArt extends StatelessWidget {
  final AudioPlayerService playerService;
  final SubsonicApi api;

  const _StaticAlbumArt({
    required this.playerService,
    required this.api,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<AudioPlayerService>(
      builder: (context, playerService, child) {
        final currentSong = playerService.currentSong;

        if (currentSong == null) {
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
          child: currentSong.coverArt != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    api.getCoverArtUrl(currentSong.coverArt!),
                    key: ValueKey('main-${currentSong.id}-${currentSong.coverArt}'),
                    fit: BoxFit.cover,
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Container(
                        color: Colors.grey[300],
                        child: Center(
                          child: CircularProgressIndicator(
                            value: loadingProgress.expectedTotalBytes != null
                                ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                                : null,
                          ),
                        ),
                      );
                    },
                    errorBuilder: (context, error, stackTrace) {
                      return const Icon(Icons.music_note, size: 64, color: Colors.grey);
                    },
                  ),
                )
              : const Icon(Icons.music_note, size: 64, color: Colors.grey),
        );
      },
    );
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