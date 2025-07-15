import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../services/subsonic_api.dart';

class AlbumList extends StatelessWidget {
  const AlbumList({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        if (appState.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        
        if (appState.error != null) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text('Error: ${appState.error}'),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => appState.loadAlbums(),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }
        
        if (appState.albums.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.library_music, size: 64, color: Colors.grey),
                const SizedBox(height: 16),
                const Text('No albums found'),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => appState.loadAlbums(),
                  child: const Text('Refresh'),
                ),
              ],
            ),
          );
        }
        
        return RefreshIndicator(
          onRefresh: () => appState.loadAlbums(),
          child: ListView.builder(
            itemCount: appState.albums.length,
            itemBuilder: (context, index) {
              final album = appState.albums[index];
              return AlbumTile(album: album);
            },
          ),
        );
      },
    );
  }
}

class AlbumTile extends StatelessWidget {
  final Album album;
  
  const AlbumTile({super.key, required this.album});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: SizedBox(
          width: 56,
          height: 56,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: Colors.grey[300],
            ),
            child: album.coverArt != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      context.read<AppState>().api!.getCoverArtUrl(album.coverArt!),
                      fit: BoxFit.cover,
                      width: 56,
                      height: 56,
                      errorBuilder: (context, error, stackTrace) {
                        return const Icon(Icons.album, color: Colors.grey);
                      },
                    ),
                  )
                : const Icon(Icons.album, color: Colors.grey),
          ),
        ),
        title: Text(
          album.name,
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(album.artist),
            if (album.songCount != null && album.duration != null)
              Text(
                '${album.songCount} songs • ${_formatDuration(album.duration!)}',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
          ],
        ),
        trailing: PopupMenuButton(
          onSelected: (value) async {
            final appState = context.read<AppState>();
            final audioPlayer = appState.audioPlayerService;
            
            if (audioPlayer != null) {
              if (value == 'play') {
                try {
                  await audioPlayer.playAlbum(album);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to play album: ${e.toString()}'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              }
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: 'play',
              child: Row(
                children: [
                  Icon(Icons.play_arrow),
                  SizedBox(width: 8),
                  Text('Play Album'),
                ],
              ),
            ),
          ],
        ),
        onTap: () async {
          final appState = context.read<AppState>();
          final audioPlayer = appState.audioPlayerService;
          
          if (audioPlayer != null) {
            try {
              await audioPlayer.playAlbum(album);
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Failed to play album: ${e.toString()}'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            }
          }
        },
      ),
    );
  }
  
  String _formatDuration(int seconds) {
    final duration = Duration(seconds: seconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else {
      return '${minutes}m';
    }
  }
}