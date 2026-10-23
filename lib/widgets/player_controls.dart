import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:logging/logging.dart';
import '../services/audio_player_service.dart';

final _log = Logger('player_controls');

class PlayerControls extends StatelessWidget {
  const PlayerControls({super.key});

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Selector<AudioPlayerService, bool>(
      selector: (context, service) => service.currentSong != null,
      builder: (context, hasSong, child) {
        if (!hasSong) {
          return const SizedBox.shrink();
        }

        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 4,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: isLandscape ? _buildLandscapeLayout() : _buildPortraitLayout(),
        );
      },
    );
  }

  Widget _buildPortraitLayout() {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ProgressSection(),
        _SleepTimerIndicator(),
        Padding(
          padding: EdgeInsets.all(16.0),
          child: Row(
            children: [
              Expanded(
                child: _SongInfo(),
              ),
              _ControlButtons(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLandscapeLayout() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Left side: Song info and sleep timer
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SongInfo(),
                    _SleepTimerIndicator(),
                  ],
                ),
              ),
              SizedBox(width: 16),
              // Right side: Controls
              _ControlButtons(),
            ],
          ),
          SizedBox(height: 8),
          // Progress section spans full width
          _ProgressSection(),
        ],
      ),
    );
  }
}

/// Builds with the playback position, which the service publishes separately
/// from its other state, and the track's duration
class _ProgressBuilder extends StatelessWidget {
  final Widget Function(
          BuildContext context, ({Duration current, Duration total}) progress)
      builder;

  const _ProgressBuilder({required this.builder});

  @override
  Widget build(BuildContext context) {
    final service = context.read<AudioPlayerService>();
    final total =
        context.select<AudioPlayerService, Duration>((s) => s.totalDuration);
    return ValueListenableBuilder<Duration>(
      valueListenable: service.position,
      builder: (context, current, child) =>
          builder(context, (current: current, total: total)),
    );
  }
}

/// The seek bar and the times next to it. While the thumb is dragged it
/// follows the finger, and the player only seeks once it's let go: a seek per
/// drag update would make the player buffer at every step, and the position
/// updates meanwhile would pull the thumb back.
class _ProgressSection extends StatefulWidget {
  const _ProgressSection();

  @override
  State<_ProgressSection> createState() => _ProgressSectionState();
}

class _ProgressSectionState extends State<_ProgressSection> {
  // The position the thumb was dragged to, shown instead of the player's
  // until the seek there has completed
  Duration? _dragPosition;
  // Incremented with every drag, so an earlier drag's seek completing doesn't
  // end a later one
  int _drag = 0;

  Duration _positionAt(double value, Duration total) =>
      Duration(milliseconds: (value * total.inMilliseconds).round());

  Future<void> _seek(Duration position) async {
    final drag = _drag;
    try {
      await context.read<AudioPlayerService>().seekTo(position);
    } catch (e) {
      _log.warning('Seek failed', e);
    }
    if (mounted && drag == _drag) setState(() => _dragPosition = null);
  }

  @override
  Widget build(BuildContext context) {
    return _ProgressBuilder(
      builder: (context, progress) {
        final total = progress.total;
        final current = _dragPosition ?? progress.current;
        final double value = total.inMilliseconds > 0
            ? current.inMilliseconds / total.inMilliseconds
            : 0;
        final canSeek = total.inMilliseconds > 0;
        final colors = Theme.of(context).colorScheme;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 20,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: value.clamp(0.0, 1.0),
                  onChangeStart: canSeek
                      ? (value) => setState(() {
                            _drag++;
                            _dragPosition = _positionAt(value, total);
                          })
                      : null,
                  onChanged: canSeek
                      ? (value) => setState(
                          () => _dragPosition = _positionAt(value, total))
                      : null,
                  onChangeEnd: canSeek
                      ? (value) => unawaited(_seek(_positionAt(value, total)))
                      : null,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final time in [current, total])
                    Text(
                      _formatDuration(time),
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SleepTimerIndicator extends StatelessWidget {
  const _SleepTimerIndicator();

  @override
  Widget build(BuildContext context) {
    return Selector<AudioPlayerService, bool>(
      selector: (context, service) => service.isSleepTimerActive,
      builder: (context, isActive, child) {
        if (!isActive) {
          return const SizedBox.shrink();
        }

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.bedtime,
                size: 16,
                color: Colors.orange,
              ),
              SizedBox(width: 8),
              _SleepTimerCountdown(),
            ],
          ),
        );
      },
    );
  }
}

/// The sleep timer's remaining time, updated every second while it's shown
class _SleepTimerCountdown extends StatefulWidget {
  const _SleepTimerCountdown();

  @override
  State<_SleepTimerCountdown> createState() => _SleepTimerCountdownState();
}

class _SleepTimerCountdownState extends State<_SleepTimerCountdown> {
  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    _updateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = context.read<AudioPlayerService>().sleepTimerRemaining;
    return Text(
      'Sleep timer: ${remaining != null ? _formatDuration(remaining) : "0:00"}',
      style: const TextStyle(
        fontSize: 12,
        color: Colors.orange,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

class _SongInfo extends StatelessWidget {
  const _SongInfo();

  @override
  Widget build(BuildContext context) {
    return Selector<AudioPlayerService, ({String title, String artist})?>(
      selector: (context, service) => service.currentSong != null
          ? (
              title: service.currentSong!.title,
              artist: service.currentSong!.artist,
            )
          : null,
      builder: (context, songInfo, child) {
        if (songInfo == null) {
          return const SizedBox.shrink();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              songInfo.title,
              style: const TextStyle(fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              songInfo.artist,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        );
      },
    );
  }
}

class _ControlButtons extends StatelessWidget {
  const _ControlButtons();

  @override
  Widget build(BuildContext context) {
    return Selector<
        AudioPlayerService,
        ({
          PlaybackState state,
          bool hasSong,
          bool hasNext,
        })>(
      selector: (context, service) => (
        state: service.playbackState,
        hasSong: service.currentSong != null,
        hasNext: service.hasNext,
      ),
      // The skip buttons stay enabled during a skip: a press moves its target
      // (see AudioPlayerService.next()), and the play button shows a
      // spinner while a track loads
      builder: (context, controls, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildSkipButton(
              icon: Icons.skip_previous,
              // Also on the first track, which Previous restarts
              enabled: controls.hasSong,
              onPressed: () => context.read<AudioPlayerService>().previous(),
            ),
            _buildPlayPauseButton(controls.state),
            _buildSkipButton(
              icon: Icons.skip_next,
              enabled: controls.hasNext,
              onPressed: () => context.read<AudioPlayerService>().next(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSkipButton({
    required IconData icon,
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: Icon(icon),
      onPressed: enabled ? onPressed : null,
    );
  }

  Widget _buildPlayPauseButton(PlaybackState state) {
    return Builder(
      builder: (context) {
        switch (state) {
          case PlaybackState.playing:
            return IconButton(
              icon: const Icon(Icons.pause),
              onPressed: () => context.read<AudioPlayerService>().pause(),
            );
          case PlaybackState.paused:
          case PlaybackState.stopped:
            return IconButton(
              icon: const Icon(Icons.play_arrow),
              onPressed: () => context.read<AudioPlayerService>().play(),
            );
          case PlaybackState.loading:
            return const Padding(
              padding: EdgeInsets.all(8.0),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
        }
      },
    );
  }
}

String _formatDuration(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  return '${minutes.toString().padLeft(1, '0')}:${seconds.toString().padLeft(2, '0')}';
}
