import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/app_state.dart';
import '../services/subsonic_api.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  SearchResult? _searchResult;
  bool _isLoading = false;
  String _errorMessage = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _searchResult = null;
        _errorMessage = '';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final appState = context.read<AppState>();
      final api = appState.api;
      if (api != null) {
        final result = await api.search(query.trim());
        if (mounted) {
          setState(() {
            _searchResult = result;
            _isLoading = false;
          });
          
          // Debug logging
          debugPrint('Search completed. Result: ${result.artists.length} artists, ${result.albums.length} albums, ${result.songs.length} songs');
          debugPrint('Result isEmpty: ${result.isEmpty}');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Search failed: ${e.toString()}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Search'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60.0),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search artists, albums, songs...',
                prefixIcon: _isLoading 
                    ? const Padding(
                        padding: EdgeInsets.all(14.0),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _performSearch('');
                        },
                      )
                    : null,
                border: const OutlineInputBorder(),
                filled: true,
                fillColor: Colors.white,
              ),
              onChanged: (value) {
                // Debounce search to avoid too many requests
                Future.delayed(const Duration(milliseconds: 500), () {
                  if (_searchController.text == value) {
                    _performSearch(value);
                  }
                });
              },
              onSubmitted: _performSearch,
            ),
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              _errorMessage,
              style: const TextStyle(fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => _performSearch(_searchController.text),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_searchResult == null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'Enter a search term to find artists, albums, and songs',
              style: TextStyle(fontSize: 16, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    if (_searchResult!.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'No results found',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return ListView(
      children: [
        if (_searchResult!.artists.isNotEmpty) ...[
          _buildSectionHeader('Artists'),
          ..._searchResult!.artists.map((artist) => _buildArtistItem(artist)),
        ],
        if (_searchResult!.albums.isNotEmpty) ...[
          _buildSectionHeader('Albums'),
          ..._searchResult!.albums.map((album) => _buildAlbumItem(album)),
        ],
        if (_searchResult!.songs.isNotEmpty) ...[
          _buildSectionHeader('Songs'),
          ..._searchResult!.songs.map((song) => _buildSongItem(song)),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildArtistItem(Artist artist) {
    return ListTile(
      leading: CircleAvatar(
        backgroundImage: artist.coverArt != null
            ? CachedNetworkImageProvider(
                context.read<AppState>().api!.getCoverArtUrl(artist.coverArt!),
              )
            : null,
        child: artist.coverArt == null ? const Icon(Icons.person) : null,
      ),
      title: Text(artist.name),
      subtitle: artist.albumCount != null
          ? Text('${artist.albumCount} albums')
          : null,
      onTap: () {
        // TODO: Navigate to artist view when implemented
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Artist browsing not implemented yet')),
        );
      },
    );
  }

  Widget _buildAlbumItem(Album album) {
    return ListTile(
      leading: album.coverArt != null
          ? CachedNetworkImage(
              imageUrl: context.read<AppState>().api!.getCoverArtUrl(album.coverArt!),
              width: 50,
              height: 50,
              fit: BoxFit.cover,
              placeholder: (context, url) => const Icon(Icons.album),
              errorWidget: (context, url, error) => const Icon(Icons.album),
            )
          : const Icon(Icons.album),
      title: Text(album.name),
      subtitle: Text(album.artist),
      onTap: () async {
        try {
          final appState = context.read<AppState>();
          final fullAlbum = await appState.api!.getAlbum(album.id);
          if (fullAlbum.songs.isNotEmpty && mounted) {
            await appState.audioPlayerService?.playAlbum(fullAlbum);
            if (mounted) {
              Navigator.of(context).pop(); // Return to home screen
            }
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error playing album: $e')),
            );
          }
        }
      },
    );
  }

  Widget _buildSongItem(Song song) {
    return ListTile(
      leading: song.coverArt != null
          ? CachedNetworkImage(
              imageUrl: context.read<AppState>().api!.getCoverArtUrl(song.coverArt!),
              width: 50,
              height: 50,
              fit: BoxFit.cover,
              placeholder: (context, url) => const Icon(Icons.music_note),
              errorWidget: (context, url, error) => const Icon(Icons.music_note),
            )
          : const Icon(Icons.music_note),
      title: Text(song.title),
      subtitle: Text('${song.artist} • ${song.album}'),
      trailing: song.duration != null
          ? Text(_formatDuration(song.duration!))
          : null,
      onTap: () async {
        try {
          final appState = context.read<AppState>();
          await appState.audioPlayerService?.playSong(song);
          if (mounted) {
            Navigator.of(context).pop(); // Return to home screen
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error playing song: $e')),
            );
          }
        }
      },
    );
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }
}