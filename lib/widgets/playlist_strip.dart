import 'package:material_ui/material_ui.dart';

import '../services/audio_player_service.dart';
import '../services/image_cache_manager.dart';
import '../services/subsonic_api.dart';

/// The queue as a horizontal strip of covers, scrolled to the current track
/// when it changes and on [scrollToCurrentTrackRequest]. [isCompact] shows
/// covers only, for landscape.
class PlaylistStrip extends StatefulWidget {
  final AudioPlayerService playerService;
  final SubsonicApi api;
  final bool isCompact;
  final Listenable? scrollToCurrentTrackRequest;

  const PlaylistStrip({
    super.key,
    required this.playerService,
    required this.api,
    this.isCompact = false,
    this.scrollToCurrentTrackRequest,
  });

  @override
  State<PlaylistStrip> createState() => _PlaylistStripState();
}

class _PlaylistStripState extends State<PlaylistStrip> {
  List<Song> _currentPlaylist = [];
  int _currentIndex = 0;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _currentPlaylist = widget.playerService.playlist;
    _currentIndex = widget.playerService.currentIndex;
    widget.playerService.addListener(_onPlayerServiceChanged);
    widget.scrollToCurrentTrackRequest?.addListener(_onScrollRequested);
  }

  @override
  void didUpdateWidget(PlaylistStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollToCurrentTrackRequest !=
        widget.scrollToCurrentTrackRequest) {
      oldWidget.scrollToCurrentTrackRequest?.removeListener(_onScrollRequested);
      widget.scrollToCurrentTrackRequest?.addListener(_onScrollRequested);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    widget.playerService.removeListener(_onPlayerServiceChanged);
    widget.scrollToCurrentTrackRequest?.removeListener(_onScrollRequested);
    super.dispose();
  }

  void _onScrollRequested() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToCurrentTrack();
    });
  }

  void _onPlayerServiceChanged() {
    // Only rebuild if the playlist or current index changed
    final newPlaylist = widget.playerService.playlist;
    final newCurrentIndex = widget.playerService.currentIndex;

    if (newPlaylist != _currentPlaylist || newCurrentIndex != _currentIndex) {
      final shouldAutoScroll = newCurrentIndex != _currentIndex;

      setState(() {
        _currentPlaylist = newPlaylist;
        _currentIndex = newCurrentIndex;
      });

      // Auto-scroll to the current track after the widget rebuilds
      if (shouldAutoScroll && _currentPlaylist.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToCurrentTrack();
        });
      }
    }
  }

  void _scrollToCurrentTrack() {
    if (!_scrollController.hasClients || _currentPlaylist.isEmpty) return;

    // Calculate the scroll position to center the current track
    // Item width depends on compact mode
    final double itemWidth = widget.isCompact
        ? 60.0 + 8.0
        : 80.0 + 8.0; // width + margin
    final double targetPosition = _currentIndex * itemWidth;

    // Get the viewport width to center the item
    final double viewportWidth = _scrollController.position.viewportDimension;
    final double centeredPosition =
        targetPosition - (viewportWidth / 2) + (itemWidth / 2);

    // Ensure we don't scroll beyond the bounds
    final double maxScrollExtent = _scrollController.position.maxScrollExtent;
    final double clampedPosition = centeredPosition.clamp(0.0, maxScrollExtent);

    _scrollController.animateTo(
      clampedPosition,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_currentPlaylist.isEmpty) return const SizedBox.shrink();

    if (widget.isCompact) {
      // Compact mode for landscape: covers only. A phone in landscape leaves
      // little height, so the label goes first and then the covers, rather
      // than overflowing.
      const labelFontSize = 12.0;
      final labelHeight =
          MediaQuery.textScalerOf(context).scale(labelFontSize) * 1.5 + 4;
      return LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          if (height < _PlaylistItem.compactHeight) {
            return const SizedBox.shrink();
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (height >= _PlaylistItem.compactHeight + labelHeight) ...[
                Text(
                  'Playlist: ${_currentIndex + 1} of ${_currentPlaylist.length}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: labelFontSize,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              SizedBox(
                height: _PlaylistItem.compactHeight,
                child: ListView.builder(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  itemCount: _currentPlaylist.length,
                  itemBuilder: (context, index) {
                    final song = _currentPlaylist[index];
                    final isCurrentSong = index == _currentIndex;

                    return _PlaylistItem(
                      key: ValueKey('playlist-item-$index'),
                      song: song,
                      isCurrentSong: isCurrentSong,
                      api: widget.api,
                      isCompact: true,
                    );
                  },
                ),
              ),
            ],
          );
        },
      );
    }

    // Full mode for portrait
    return Column(
      children: [
        const Divider(),
        Text(
          'Playlist: ${_currentIndex + 1} of ${_currentPlaylist.length}',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 100,
          child: ListView.builder(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            itemCount: _currentPlaylist.length,
            itemBuilder: (context, index) {
              final song = _currentPlaylist[index];
              final isCurrentSong = index == _currentIndex;

              return _PlaylistItem(
                key: ValueKey('playlist-item-$index'),
                song: song,
                isCurrentSong: isCurrentSong,
                api: widget.api,
                isCompact: false,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PlaylistItem extends StatelessWidget {
  /// Height of a compact item: just its cover
  static const compactHeight = 40.0;

  final Song song;
  final bool isCurrentSong;
  final SubsonicApi api;
  final bool isCompact;

  const _PlaylistItem({
    super.key,
    required this.song,
    required this.isCurrentSong,
    required this.api,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    final itemSize = isCompact ? compactHeight : 60.0;
    final containerWidth = isCompact ? 60.0 : 80.0;
    final fontSize = isCompact ? 8.0 : 10.0;
    final iconSize = isCompact ? 16.0 : 24.0;

    return Container(
      width: containerWidth,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        children: [
          Container(
            width: itemSize,
            height: itemSize,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(isCompact ? 6 : 8),
              color: isCurrentSong
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              border: isCurrentSong
                  ? Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: isCompact ? 2 : 3,
                    )
                  : null,
              boxShadow: isCurrentSong
                  ? [
                      BoxShadow(
                        color: Theme.of(context).colorScheme.primary
                            .withValues(alpha: 0.3),
                        blurRadius: isCompact ? 4 : 8,
                        spreadRadius: isCompact ? 0.5 : 1,
                      ),
                    ]
                  : null,
            ),
            child: Stack(
              children: [
                song.coverArt != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(isCompact ? 6 : 8),
                        child: ImageCacheManager.buildCoverArt(
                          api: api,
                          coverArtId: song.coverArt!,
                          key: ValueKey('playlist-${song.id}-${song.coverArt}'),
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Icon(
                            Icons.music_note,
                            color: isCurrentSong
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                            size: iconSize * 0.8,
                          ),
                          errorWidget: (context, url, error) => Icon(
                            Icons.music_note,
                            color: isCurrentSong
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                            size: iconSize * 0.8,
                          ),
                        ),
                      )
                    : Icon(
                        Icons.music_note,
                        color: isCurrentSong
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        size: iconSize * 0.8,
                      ),
                if (isCurrentSong)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(isCompact ? 6 : 8),
                        color: Colors.black.withValues(alpha: 0.3),
                      ),
                      child: Icon(
                        Icons.play_arrow,
                        color: Colors.white,
                        size: iconSize,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (!isCompact) ...[
            const SizedBox(height: 4),
            Text(
              song.title,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: isCurrentSong ? FontWeight.bold : FontWeight.normal,
                color: isCurrentSong
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}
