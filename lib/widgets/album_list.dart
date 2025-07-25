import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../services/subsonic_api.dart';
import '../services/audio_player_service.dart';
import '../services/image_cache_manager.dart';

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

        final isLandscape =
            MediaQuery.of(context).orientation == Orientation.landscape;

        return RefreshIndicator(
          onRefresh: () => appState.loadAlbums(),
          child: isLandscape
              ? GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.85,
                  ),
                  itemCount: appState.albums.length,
                  itemBuilder: (context, index) {
                    final album = appState.albums[index];
                    return AlbumGridTile(album: album);
                  },
                )
              : ListView.builder(
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
                    ? ImageCacheManager.buildAlbumArt(
                        imageUrl: appState.api!
                            .getCoverArtUrl(widget.album.coverArt!),
                        size: 56,
                        cacheKey: widget.album.coverArt,
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
                if (widget.album.songCount != null &&
                    widget.album.duration != null)
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

  Future<void> _playAlbum(
      AppState appState, AudioPlayerService audioPlayer) async {
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

class AlbumGridTile extends StatefulWidget {
  final Album album;

  const AlbumGridTile({super.key, required this.album});

  @override
  State<AlbumGridTile> createState() => _AlbumGridTileState();
}

class _AlbumGridTileState extends State<AlbumGridTile> {
  bool _isPlayingAlbum = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        return Card(
          elevation: 2,
          child: InkWell(
            onTap: () async {
              final audioPlayer = appState.audioPlayerService;

              if (audioPlayer != null) {
                await _playAlbum(appState, audioPlayer);
              }
            },
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Album art
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: Colors.grey[300],
                      ),
                      child: widget.album.coverArt != null
                          ? ImageCacheManager.buildAlbumArt(
                              imageUrl: appState.api!
                                  .getCoverArtUrl(widget.album.coverArt!),
                              size: 120,
                              cacheKey: widget.album.coverArt,
                            )
                          : const Icon(Icons.album,
                              color: Colors.grey, size: 48),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Album title
                  Text(
                    widget.album.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // Artist name
                  Text(
                    widget.album.artist,
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // Loading indicator or play button
                  if (_isPlayingAlbum)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _playAlbum(
      AppState appState, AudioPlayerService audioPlayer) async {
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
}
