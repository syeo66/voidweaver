import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/image_cache_manager.dart';
import '../services/subsonic_api.dart';
import '../services/network_errors.dart';
import '../widgets/artist_albums_view.dart';

class ArtistScreen extends StatefulWidget {
  const ArtistScreen({super.key});

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  List<Artist> _artists = [];
  // Its albums are shown instead of the artists
  Artist? _selectedArtist;
  bool _isLoadingArtists = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    unawaited(_loadArtists());
  }

  Future<void> _loadArtists() async {
    final api = context.read<AppState>().api;
    if (api == null) return;

    setState(() {
      _isLoadingArtists = true;
      _errorMessage = null;
    });

    try {
      final artists = await api.getArtists();
      if (!mounted) return;
      setState(() {
        _artists = artists;
        _isLoadingArtists = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingArtists = false;
        _errorMessage = NetworkErrorHelper.getErrorMessage(
          e,
          context: 'Failed to load artists',
        );
      });
    }
  }

  void _showArtist(Artist? artist) {
    setState(() => _selectedArtist = artist);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectedArtist?.name ?? 'Artists'),
        leading: _selectedArtist != null
            ? BackButton(onPressed: () => _showArtist(null))
            : null,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final artist = _selectedArtist;
    if (artist != null) {
      // Keyed, so another artist's albums never show up, see
      // ArtistAlbumsView
      return ArtistAlbumsView(key: ValueKey(artist.id), artist: artist);
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadArtists, child: const Text('Retry')),
          ],
        ),
      );
    }

    return _buildArtistList();
  }

  Widget _buildArtistList() {
    if (_isLoadingArtists) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading artists...'),
          ],
        ),
      );
    }

    if (_artists.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.person_outline,
              size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            const Text('No artists found'),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loadArtists,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadArtists,
      child: ListView.builder(
        itemCount: _artists.length,
        itemBuilder: (context, index) {
          final artist = _artists[index];
          return _buildArtistTile(artist);
        },
      ),
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
      onTap: () => _showArtist(artist),
    );
  }

  Widget _buildArtistAvatar(Artist artist) {
    final appState = context.read<AppState>();
    final api = appState.api;

    if (artist.coverArt != null && api != null) {
      return CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        backgroundImage: ImageCacheManager.coverArtProvider(
          api,
          artist.coverArt!,
        ),
      );
    }

    return CircleAvatar(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Text(
        artist.name.isNotEmpty ? artist.name[0].toUpperCase() : '?',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
