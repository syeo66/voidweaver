import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../models/album_list_type.dart';
import 'album_tile.dart';

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
        if (appState.albumError != null && appState.albums.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 64,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(appState.albumError!),
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
                Icon(
                  Icons.library_music,
                  size: 64,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Text(
                  nothingPlayed ? 'No albums played yet' : 'No albums found',
                ),
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
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('Refresh failed: $error')));
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
