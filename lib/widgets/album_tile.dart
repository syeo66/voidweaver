import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/image_cache_manager.dart';
import '../services/network_errors.dart';
import '../services/subsonic_api.dart';
import '../utils/format.dart';

/// Plays [album], showing a snack bar if that fails. Returns whether it
/// started. The snack bar is shown even if the widget behind [context] is
/// gone by then (e.g. scrolled away).
Future<bool> playAlbumWithFeedback(BuildContext context, Album album) async {
  final player = context.read<AppState>().audioPlayerService;
  if (player == null) return false;
  final messenger = ScaffoldMessenger.of(context);
  final errorColor = Theme.of(context).colorScheme.error;
  try {
    await player.playAlbum(album);
    return true;
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          NetworkErrorHelper.getErrorMessage(
            e,
            context: 'Failed to play album',
          ),
        ),
        backgroundColor: errorColor,
      ),
    );
    return false;
  }
}

/// Plays the tile's album on tap, with a spinner while it starts. A tap
/// meanwhile is ignored.
mixin _PlaysAlbum<T extends StatefulWidget> on State<T> {
  bool _starting = false;

  Future<void> _play(Album album) async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      await playAlbumWithFeedback(context, album);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
}

/// An album in a list: cover, name, artist, length. Plays it on tap.
class AlbumTile extends StatefulWidget {
  final Album album;

  const AlbumTile({super.key, required this.album});

  @override
  State<AlbumTile> createState() => _AlbumTileState();
}

class _AlbumTileState extends State<AlbumTile> with _PlaysAlbum {
  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    final api = context.watch<AppState>().api;
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: SizedBox(
          width: 56,
          height: 56,
          child: album.coverArt != null && api != null
              ? ImageCacheManager.buildAlbumArt(
                  api: api,
                  coverArtId: album.coverArt!,
                  size: 56,
                )
              : DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: colors.surfaceContainerHighest,
                  ),
                  child: Icon(Icons.album, color: colors.onSurfaceVariant),
                ),
        ),
        title: Text(
          album.name,
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(album.artist),
            if (album.songCount != null && album.duration != null)
              Text(
                '${album.songCount} songs • ${formatHoursMinutes(Duration(seconds: album.duration!))}',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
          ],
        ),
        trailing: _starting
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : PopupMenuButton<String>(
                onSelected: (_) => _play(album),
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
        onTap: () => _play(album),
      ),
    );
  }
}

/// An album in a grid: cover filling the top, name and a second line below.
/// Plays it on tap.
class AlbumGridTile extends StatefulWidget {
  final Album album;

  /// Shows the artist on the second line; otherwise the number of songs (for
  /// an artist's albums, where the artist is known)
  final bool showArtist;

  const AlbumGridTile({super.key, required this.album, this.showArtist = true});

  @override
  State<AlbumGridTile> createState() => _AlbumGridTileState();
}

class _AlbumGridTileState extends State<AlbumGridTile> with _PlaysAlbum {
  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    final api = context.watch<AppState>().api;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final placeholderIcon = Icon(
      Icons.album,
      size: 48,
      color: colors.onSurfaceVariant,
    );
    final secondLine = widget.showArtist
        ? album.artist
        : (album.songCount != null ? '${album.songCount} songs' : null);

    return Card(
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _play(album),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: colors.surfaceContainerHighest,
                    child: album.coverArt != null && api != null
                        ? ImageCacheManager.buildCoverArt(
                            api: api,
                            coverArtId: album.coverArt!,
                            fit: BoxFit.cover,
                            errorWidget: (context, url, error) =>
                                Center(child: placeholderIcon),
                          )
                        : Center(child: placeholderIcon),
                  ),
                  if (_starting)
                    const ColoredBox(
                      color: Colors.black38,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (secondLine != null)
                    Text(
                      secondLine,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
