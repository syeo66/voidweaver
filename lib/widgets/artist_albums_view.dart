import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../services/network_errors.dart';
import '../services/subsonic_api.dart';
import 'album_tile.dart';

/// The albums of [artist] in a grid, loaded when shown; tapping one plays
/// it. A response arriving after the view is gone is dropped, so give it a
/// key per artist where it can be switched to another artist.
class ArtistAlbumsView extends StatefulWidget {
  final Artist artist;

  const ArtistAlbumsView({super.key, required this.artist});

  @override
  State<ArtistAlbumsView> createState() => _ArtistAlbumsViewState();
}

class _ArtistAlbumsViewState extends State<ArtistAlbumsView> {
  List<Album> _albums = [];
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;

    setState(() {
      _isLoading = true;
      _albums = [];
      _errorMessage = null;
    });

    try {
      final albums = await api.getArtistAlbums(widget.artist.id);
      if (!mounted) return;
      setState(() {
        _albums = albums;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = NetworkErrorHelper.getErrorMessage(e,
            context: 'Failed to load albums for ${widget.artist.name}');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mutedColor = Theme.of(context).colorScheme.onSurfaceVariant;

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: mutedColor),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _load,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_isLoading) {
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
            Icon(Icons.album_outlined, size: 64, color: mutedColor),
            const SizedBox(height: 16),
            const Text('No albums found for this artist'),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.8,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
        ),
        itemCount: _albums.length,
        itemBuilder: (context, index) =>
            AlbumGridTile(album: _albums[index], showArtist: false),
      ),
    );
  }
}
