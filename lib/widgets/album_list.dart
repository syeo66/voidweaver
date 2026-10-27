import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../models/album_list_type.dart';
import '../services/subsonic_api.dart';
import '../services/audio_player_service.dart';
import '../services/image_cache_manager.dart';
import '../services/network_errors.dart';

class AlbumList extends StatelessWidget {
  const AlbumList({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const _AlbumListTypeSelector(),
        Expanded(child: _buildAlbums()),
      ],
    );
  }

  Widget _buildAlbums() {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        // On a refresh, the RefreshIndicator shows the progress
        if (appState.isLoading && appState.albums.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        // A failed refresh keeps the albums loaded before (see onRefresh)
        if (appState.error != null && appState.albums.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline,
                    size: 64, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 16),
                Text(appState.error!),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => appState.loadAlbums(forceRefresh: true),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }

        if (appState.albums.isEmpty) {
          // Nothing played yet, e.g. a new account: a refresh won't help
          final nothingPlayed = appState.albumListType == AlbumListType.recent;
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.library_music,
                    size: 64,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(height: 16),
                Text(
                    nothingPlayed ? 'No albums played yet' : 'No albums found'),
                const SizedBox(height: 16),
                if (nothingPlayed)
                  ElevatedButton(
                    onPressed: () =>
                        appState.setAlbumListType(AlbumListType.newest),
                    child: const Text('Show recently added'),
                  )
                else
                  ElevatedButton(
                    onPressed: () => appState.loadAlbums(forceRefresh: true),
                    child: const Text('Refresh'),
                  ),
              ],
            ),
          );
        }

        final isLandscape =
            MediaQuery.of(context).orientation == Orientation.landscape;

        return RefreshIndicator(
          onRefresh: () async {
            await appState.loadAlbums(forceRefresh: true);
            final error = appState.albumError;
            if (error != null && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Refresh failed: $error')),
              );
            }
          },
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

/// Switches the album list between recently played and recently added
class _AlbumListTypeSelector extends StatelessWidget {
  const _AlbumListTypeSelector();

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<AlbumListType>(
          segments: const [
            ButtonSegment(
              value: AlbumListType.recent,
              icon: Icon(Icons.history),
              label: Text('Recently played'),
            ),
            ButtonSegment(
              value: AlbumListType.newest,
              icon: Icon(Icons.new_releases_outlined),
              label: Text('Recently added'),
            ),
          ],
          selected: {appState.albumListType},
          showSelectedIcon: false,
          onSelectionChanged: (selected) =>
              appState.setAlbumListType(selected.single),
        ),
      ),
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
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                child: widget.album.coverArt != null
                    ? ImageCacheManager.buildAlbumArt(
                        api: appState.api!,
                        coverArtId: widget.album.coverArt!,
                        size: 56,
                      )
                    : Icon(Icons.album,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
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
            content: Text(NetworkErrorHelper.getErrorMessage(e,
                context: 'Failed to play album')),
            backgroundColor: Theme.of(context).colorScheme.error,
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
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                      ),
                      child: widget.album.coverArt != null
                          ? ImageCacheManager.buildAlbumArt(
                              api: appState.api!,
                              coverArtId: widget.album.coverArt!,
                              size: 120,
                            )
                          : Icon(Icons.album,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              size: 48),
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
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
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
            content: Text(NetworkErrorHelper.getErrorMessage(e,
                context: 'Failed to play album')),
            backgroundColor: Theme.of(context).colorScheme.error,
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
