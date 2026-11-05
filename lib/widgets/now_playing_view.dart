import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/audio_player_service.dart';
import '../services/image_cache_manager.dart';
import '../services/subsonic_api.dart';
import 'playlist_strip.dart';

/// The Now Playing tab: cover, song info and the queue. Expects the
/// [AudioPlayerService] from a provider above it.
class NowPlayingView extends StatelessWidget {
  final AppState appState;
  final Listenable scrollToCurrentTrackRequest;

  const NowPlayingView({
    super.key,
    required this.appState,
    required this.scrollToCurrentTrackRequest,
  });

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Consumer<AudioPlayerService>(
      builder: (context, playerService, child) {
        final currentSong = playerService.currentSong;

        if (currentSong == null) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.music_off,
                  size: 64,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                SizedBox(height: 16),
                Text(
                  'No song playing',
                  style: TextStyle(
                    fontSize: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }

        // Return child that contains static widgets
        return child!;
      },
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: isLandscape ? _buildLandscapeLayout() : _buildPortraitLayout(),
      ),
    );
  }

  Widget _buildPortraitLayout() {
    return Column(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _StaticAlbumArt(
                playerService: appState.audioPlayerService!,
                api: appState.api!,
              ),
              const SizedBox(height: 24),
              const _StaticSongInfo(),
            ],
          ),
        ),
        PlaylistStrip(
          playerService: appState.audioPlayerService!,
          api: appState.api!,
          scrollToCurrentTrackRequest: scrollToCurrentTrackRequest,
        ),
      ],
    );
  }

  Widget _buildLandscapeLayout() {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              // Left side: Album art
              Expanded(
                flex: 1,
                child: Center(
                  child: _StaticAlbumArt(
                    playerService: appState.audioPlayerService!,
                    api: appState.api!,
                  ),
                ),
              ),
              const SizedBox(width: 24),
              // Right side: Song info and controls
              Expanded(
                flex: 1,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const _StaticSongInfo(),
                    const SizedBox(height: 24),
                    // Compact playlist in landscape
                    Flexible(
                      child: PlaylistStrip(
                        playerService: appState.audioPlayerService!,
                        api: appState.api!,
                        isCompact: true,
                        scrollToCurrentTrackRequest:
                            scrollToCurrentTrackRequest,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StaticAlbumArt extends StatefulWidget {
  final AudioPlayerService playerService;
  final SubsonicApi api;

  const _StaticAlbumArt({required this.playerService, required this.api});

  @override
  State<_StaticAlbumArt> createState() => _StaticAlbumArtState();
}

class _StaticAlbumArtState extends State<_StaticAlbumArt> {
  Song? _currentSong;
  String? _currentCoverArt;
  Widget? _cachedImageWidget;

  @override
  void initState() {
    super.initState();
    _currentSong = widget.playerService.currentSong;
    _updateCoverArt();
    widget.playerService.addListener(_onPlayerServiceChanged);
  }

  @override
  void dispose() {
    widget.playerService.removeListener(_onPlayerServiceChanged);
    super.dispose();
  }

  void _updateCoverArt() {
    final newCoverArt = _currentSong?.coverArt;
    if (newCoverArt != _currentCoverArt) {
      _currentCoverArt = newCoverArt;
      _cachedImageWidget = null; // Clear cache when the cover changes
    }
  }

  void _onPlayerServiceChanged() {
    final newSong = widget.playerService.currentSong;

    // Update the display when the song actually changes
    final songChanged = newSong?.id != _currentSong?.id;

    if (songChanged) {
      setState(() {
        _currentSong = newSong;
        _updateCoverArt();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_currentSong == null) {
      return Container(
        width: 200,
        height: 200,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: Icon(
          Icons.music_note,
          size: 64,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }

    return Container(
      width: 200,
      height: 200,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: _currentCoverArt != null
          ? _buildCachedImage()
          : Icon(
              Icons.music_note,
              size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
    );
  }

  Widget _buildCachedImage() {
    if (_cachedImageWidget != null) {
      return _cachedImageWidget!;
    }

    _cachedImageWidget = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ImageCacheManager.buildCoverArt(
        api: widget.api,
        coverArtId: _currentCoverArt!,
        key: ValueKey('main-$_currentCoverArt'),
        fit: BoxFit.cover,
        placeholder: (context, url) => Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
        errorWidget: (context, url, error) => Icon(
          Icons.music_note,
          size: 64,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );

    return _cachedImageWidget!;
  }
}

class _StaticSongInfo extends StatelessWidget {
  const _StaticSongInfo();

  @override
  Widget build(BuildContext context) {
    return Consumer<AudioPlayerService>(
      builder: (context, playerService, child) {
        final currentSong = playerService.currentSong;

        if (currentSong == null) {
          return const SizedBox.shrink();
        }

        return Column(
          children: [
            Text(
              currentSong.title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              currentSong.artist,
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              currentSong.album,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        );
      },
    );
  }
}
