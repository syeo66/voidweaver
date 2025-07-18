import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/app_state.dart';
import '../services/subsonic_api.dart';
import '../services/audio_player_service.dart';

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

class AlbumTile extends StatefulWidget {
  final Album album;
  
  const AlbumTile({super.key, required this.album});

  @override
  State<AlbumTile> createState() => _AlbumTileState();
}

class _AlbumTileState extends State<AlbumTile> {
  bool _isPlayingAlbum = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
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
                child: widget.album.coverArt != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CachedNetworkImage(
                          imageUrl: appState.api!.getCoverArtUrl(widget.album.coverArt!),
                          fit: BoxFit.cover,
                          width: 56,
                          height: 56,
                          placeholder: (context, url) => Container(
                            color: Colors.grey[300],
                            child: const Icon(Icons.album, color: Colors.grey),
                          ),
                          errorWidget: (context, url, error) => const Icon(Icons.album, color: Colors.grey),
                        ),
                      )
                    : const Icon(Icons.album, color: Colors.grey),
              ),
            ),
            title: Text(
              widget.album.name,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.album.artist),
                if (widget.album.songCount != null && widget.album.duration != null)
                  Text(
                    '${widget.album.songCount} songs • ${_formatDuration(widget.album.duration!)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
              ],
            ),
            trailing: _isPlayingAlbum
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : PopupMenuButton(
                    onSelected: (value) async {
                      final audioPlayer = appState.audioPlayerService;
                      
                      if (audioPlayer != null) {
                        if (value == 'play') {
                          await _playAlbum(appState, audioPlayer);
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
              final audioPlayer = appState.audioPlayerService;
              
              if (audioPlayer != null) {
                await _playAlbum(appState, audioPlayer);
              }
            },
          ),
        );
      },
    );
  }

  Future<void> _playAlbum(AppState appState, AudioPlayerService audioPlayer) async {
    if (_isPlayingAlbum) return;
    
    setState(() => _isPlayingAlbum = true);
    
    try {
      await audioPlayer.playAlbum(widget.album);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to play album: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isPlayingAlbum = false);
      }
    }
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