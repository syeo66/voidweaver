import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/app_state.dart';
import '../services/subsonic_api.dart';

class ArtistScreen extends StatefulWidget {
  const ArtistScreen({super.key});

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  List<Artist> _artists = [];
  List<Album> _albums = [];
  Artist? _selectedArtist;
  bool _isLoadingArtists = false;
  bool _isLoadingAlbums = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadArtists();
  }

  Future<void> _loadArtists() async {
    setState(() {
      _isLoadingArtists = true;
      _errorMessage = null;
    });

    try {
      final appState = context.read<AppState>();
      final api = appState.api;
      if (api != null) {
        final artists = await api.getArtists();
        setState(() {
          _artists = artists;
          _isLoadingArtists = false;
        });
      }
    } catch (e) {
      setState(() {
        _isLoadingArtists = false;
        _errorMessage = 'Failed to load artists: $e';
      });
    }
  }

  Future<void> _loadArtistAlbums(Artist artist) async {
    setState(() {
      _selectedArtist = artist;
      _isLoadingAlbums = true;
      _albums = [];
      _errorMessage = null;
    });

    try {
      final appState = context.read<AppState>();
      final api = appState.api;
      if (api != null) {
        final albums = await api.getArtistAlbums(artist.id);
        setState(() {
          _albums = albums;
          _isLoadingAlbums = false;
        });
      }
    } catch (e) {
      setState(() {
        _isLoadingAlbums = false;
        _errorMessage = 'Failed to load albums for ${artist.name}: $e';
      });
    }
  }

  Future<void> _playAlbum(Album album) async {
    final appState = context.read<AppState>();
    await appState.audioPlayerService?.playAlbum(album);
  }

  void _backToArtists() {
    setState(() {
      _selectedArtist = null;
      _albums = [];
      _errorMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectedArtist?.name ?? 'Artists'),
        leading: _selectedArtist != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _backToArtists,
              )
            : null,
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
              onPressed: _selectedArtist != null
                  ? () => _loadArtistAlbums(_selectedArtist!)
                  : _loadArtists,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_selectedArtist == null) {
      return _buildArtistList();
    } else {
      return _buildAlbumList();
    }
  }

  Widget _buildArtistList() {
    if (_isLoadingArtists) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_artists.isEmpty) {
      return const Center(
        child: Text('No artists found'),
      );
    }

    return ListView.builder(
      itemCount: _artists.length,
      itemBuilder: (context, index) {
        final artist = _artists[index];
        return _buildArtistTile(artist);
      },
    );
  }

  Widget _buildArtistTile(Artist artist) {
    return ListTile(
      leading: _buildArtistAvatar(artist),
      title: Text(artist.name),
      subtitle: artist.albumCount != null
          ? Text('${artist.albumCount} albums')
          : null,
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _loadArtistAlbums(artist),
    );
  }

  Widget _buildArtistAvatar(Artist artist) {
    final appState = context.read<AppState>();
    final api = appState.api;
    
    if (artist.coverArt != null && api != null) {
      return CircleAvatar(
        backgroundColor: Colors.grey[300],
        backgroundImage: CachedNetworkImageProvider(
          api.getCoverArtUrl(artist.coverArt!),
        ),
      );
    }

    return CircleAvatar(
      backgroundColor: Colors.grey[300],
      child: Text(
        artist.name.isNotEmpty ? artist.name[0].toUpperCase() : '?',
        style: const TextStyle(
          color: Colors.grey,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildAlbumList() {
    if (_isLoadingAlbums) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_albums.isEmpty) {
      return const Center(
        child: Text('No albums found for this artist'),
      );
    }

    return GridView.builder(
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