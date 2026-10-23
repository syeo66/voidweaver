import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../services/image_cache_manager.dart';
import '../services/subsonic_api.dart';
import 'artist_detail_screen.dart';
import '../services/network_errors.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  SearchResult? _searchResult;
  bool _isLoading = false;
  String _errorMessage = '';
  late TabController _tabController;
  // Runs the search once typing pauses, see _onQueryChanged()
  Timer? _debounce;
  // Incremented for every search; a response to an older one is dropped
  int _searchGeneration = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    _debounce =
        Timer(const Duration(milliseconds: 500), () => _performSearch(query));
  }

  Future<void> _performSearch(String query) async {
    _debounce?.cancel();
    final generation = ++_searchGeneration;
    if (query.trim().isEmpty) {
      setState(() {
        _searchResult = null;
        _errorMessage = '';
        // A search still running is dropped, see _searchGeneration
        _isLoading = false;
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
        if (mounted && generation == _searchGeneration) {
          setState(() {
            _searchResult = result;
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted && generation == _searchGeneration) {
        setState(() {
          _isLoading = false;
          _errorMessage =
              NetworkErrorHelper.getErrorMessage(e, context: 'Search failed');
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
          preferredSize: const Size.fromHeight(110.0),
          child: Column(
            children: [
              Padding(
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
                            tooltip: 'Clear search',
                            onPressed: () {
                              _searchController.clear();
                              unawaited(_performSearch(''));
                            },
                          )
                        : null,
                    border: const OutlineInputBorder(),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surface,
                  ),
                  onChanged: _onQueryChanged,
                  onSubmitted: _performSearch,
                ),
              ),
              if (_searchResult != null && _searchResult!.isNotEmpty)
                TabBar(
                  controller: _tabController,
                  tabs: [
                    Tab(
                      text: 'Artists (${_searchResult!.artists.length})',
                    ),
                    Tab(
                      text: 'Albums (${_searchResult!.albums.length})',
                    ),
                    Tab(
                      text: 'Songs (${_searchResult!.songs.length})',
                    ),
                  ],
                ),
            ],
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
            Icon(Icons.error_outline,
                size: 64, color: Theme.of(context).colorScheme.error),
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
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search,
                size: 64,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            SizedBox(height: 16),
            Text(
              'Enter a search term to find artists, albums, and songs',
              style: TextStyle(
                  fontSize: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    if (_searchResult!.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off,
                size: 64,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            SizedBox(height: 16),
            Text(
              'No results found',
              style: TextStyle(
                  fontSize: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return TabBarView(
      controller: _tabController,
      children: [
        _buildArtistsList(),
        _buildAlbumsList(),
        _buildSongsList(),
      ],
    );
  }

  Widget _buildArtistsList() {
    if (_searchResult!.artists.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.person_search,
                size: 64,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            SizedBox(height: 16),
            Text(
              'No artists found',
              style: TextStyle(
                  fontSize: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _searchResult!.artists.length,
      itemBuilder: (context, index) {
        return _buildArtistItem(_searchResult!.artists[index]);
      },
    );
  }

  Widget _buildAlbumsList() {
    if (_searchResult!.albums.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.album,
                size: 64,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            SizedBox(height: 16),
            Text(
              'No albums found',
              style: TextStyle(
                  fontSize: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _searchResult!.albums.length,
      itemBuilder: (context, index) {
        return _buildAlbumItem(_searchResult!.albums[index]);
      },
    );
  }

  Widget _buildSongsList() {
    if (_searchResult!.songs.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.music_note,
                size: 64,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            SizedBox(height: 16),
            Text(
              'No songs found',
              style: TextStyle(
                  fontSize: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _searchResult!.songs.length,
      itemBuilder: (context, index) {
        return _buildSongItem(_searchResult!.songs[index]);
      },
    );
  }

  Widget _buildArtistItem(Artist artist) {
    return ListTile(
      leading: CircleAvatar(
        backgroundImage: artist.coverArt != null
            ? ImageCacheManager.coverArtProvider(
                context.read<AppState>().api!, artist.coverArt!)
            : null,
        child: artist.coverArt == null ? const Icon(Icons.person) : null,
      ),
      title: Text(artist.name),
      subtitle: artist.albumCount != null
          ? Text('${artist.albumCount} albums')
          : null,
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ArtistDetailScreen(artist: artist),
          ),
        );
      },
    );
  }

  Widget _buildAlbumItem(Album album) {
    return ListTile(
      leading: album.coverArt != null
          ? ImageCacheManager.buildCoverArt(
              api: context.read<AppState>().api!,
              coverArtId: album.coverArt!,
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
              SnackBar(
                  content: Text(NetworkErrorHelper.getErrorMessage(e,
                      context: 'Failed to play album'))),
            );
          }
        }
      },
    );
  }

  Widget _buildSongItem(Song song) {
    return ListTile(
      leading: song.coverArt != null
          ? ImageCacheManager.buildCoverArt(
              api: context.read<AppState>().api!,
              coverArtId: song.coverArt!,
              width: 50,
              height: 50,
              fit: BoxFit.cover,
              placeholder: (context, url) => const Icon(Icons.music_note),
              errorWidget: (context, url, error) =>
                  const Icon(Icons.music_note),
            )
          : const Icon(Icons.music_note),
      title: Text(song.title),
      subtitle: Text('${song.artist} • ${song.album}'),
      trailing:
          song.duration != null ? Text(_formatDuration(song.duration!)) : null,
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
              SnackBar(
                  content: Text(NetworkErrorHelper.getErrorMessage(e,
                      context: 'Failed to play song'))),
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
