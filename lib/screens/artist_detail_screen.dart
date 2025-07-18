import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/app_state.dart';
import '../services/subsonic_api.dart';

class ArtistDetailScreen extends StatefulWidget {
  final Artist artist;

  const ArtistDetailScreen({
    super.key,
    required this.artist,
  });

  @override
  State<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends State<ArtistDetailScreen> {
  List<Album> _albums = [];
  bool _isLoadingAlbums = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadArtistAlbums();
  }

  Future<void> _loadArtistAlbums() async {
    setState(() {
      _isLoadingAlbums = true;
      _albums = [];
      _errorMessage = null;
    });

    try {
      final appState = context.read<AppState>();
      final api = appState.api;
      if (api != null) {
        final albums = await api.getArtistAlbums(widget.artist.id);
        setState(() {
          _albums = albums;
          _isLoadingAlbums = false;
        });
      }
    } catch (e) {
      setState(() {
        _isLoadingAlbums = false;
        _errorMessage = 'Failed to load albums for ${widget.artist.name}: $e';
      });
    }
  }

  Future<void> _playAlbum(Album album) async {
    try {
      final appState = context.read<AppState>();
      await appState.audioPlayerService?.playAlbum(album);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to play album: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.artist.name),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: Colors.grey[600],
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadArtistAlbums,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_isLoadingAlbums) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading albums...'),
          ],
        ),
      );
    }

    if (_albums.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.album_outlined, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('No albums found for this artist'),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loadArtistAlbums,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadArtistAlbums,
      child: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.8,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
        ),
        itemCount: _albums.length,
        itemBuilder: (context, index) {
          final album = _albums[index];
          return _buildAlbumCard(album);
        },
      ),
    );
  }

  Widget _buildAlbumCard(Album album) {
    final appState = context.read<AppState>();
    final api = appState.api;

    return Card(
      elevation: 2,
      child: InkWell(
        onTap: () => _playAlbum(album),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4),
                  ),
                ),
                child: album.coverArt != null && api != null
                    ? CachedNetworkImage(
                        imageUrl: api.getCoverArtUrl(album.coverArt!),
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Container(
                          color: Colors.grey[300],
                          child: const Center(
                            child: CircularProgressIndicator(),
                          ),
                        ),
                        errorWidget: (context, url, error) => Container(
                          color: Colors.grey[300],
                          child: const Icon(
                            Icons.music_note,
                            size: 48,
                            color: Colors.grey,
                          ),
                        ),
                      )
                    : const Icon(
                        Icons.music_note,
                        size: 48,
                        color: Colors.grey,
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.name,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (album.songCount != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${album.songCount} songs',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey[600],
                          ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}