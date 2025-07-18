import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/audio_player_service.dart';

class PlayerControls extends StatelessWidget {
  const PlayerControls({super.key});

  @override
  Widget build(BuildContext context) {
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
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ProgressSection(),
              _TimeLabels(),
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
          ),
        );
      },
    );
  }
}

class _ProgressSection extends StatelessWidget {
  const _ProgressSection();

  @override
  Widget build(BuildContext context) {
    return Selector<AudioPlayerService, ({Duration current, Duration total})>(
      selector: (context, service) => (
        current: service.currentPosition,
        total: service.totalDuration,
      ),
      builder: (context, progress, child) {
        final double value = progress.total.inMilliseconds > 0
            ? progress.current.inMilliseconds / progress.total.inMilliseconds
            : 0;
        
        return SizedBox(
          height: 20,
          child: Builder(
            builder: (context) => SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: Colors.blue,
                inactiveTrackColor: Colors.grey[300],
                thumbColor: Colors.blue,
                overlayColor: Colors.blue.withValues(alpha: 0.2),
              ),
              child: Slider(
                value: value.clamp(0.0, 1.0),
                onChanged: (newValue) {
                  if (progress.total.inMilliseconds > 0) {
                    final newPosition = Duration(
                      milliseconds: (newValue * progress.total.inMilliseconds).round(),
                    );
                    context.read<AudioPlayerService>().seekTo(newPosition);
                  }
                },
              ),
            ),
          ),
        );
      },
    );
  }
  
}

class _TimeLabels extends StatelessWidget {
  const _TimeLabels();

  @override
  Widget build(BuildContext context) {
    return Selector<AudioPlayerService, ({Duration current, Duration total})>(
      selector: (context, service) => (
        current: service.currentPosition,
        total: service.totalDuration,
      ),
      builder: (context, progress, child) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(progress.current),
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                ),
              ),
              Text(
                _formatDuration(progress.total),
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
  
}

class _SleepTimerIndicator extends StatelessWidget {
  const _SleepTimerIndicator();

  @override
  Widget build(BuildContext context) {
    return Selector<AudioPlayerService, ({bool isActive, Duration? remaining})>(
      selector: (context, service) => (
        isActive: service.isSleepTimerActive,
        remaining: service.sleepTimerRemaining,
      ),
      builder: (context, timer, child) {
        if (!timer.isActive) {
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.bedtime,
                size: 16,
                color: Colors.orange,
              ),
              const SizedBox(width: 8),
              Text(
                'Sleep timer: ${timer.remaining != null ? _formatDuration(timer.remaining!) : "0:00"}',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.orange,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        );
      },
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
              style: TextStyle(color: Colors.grey[600]),
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
    return Selector<AudioPlayerService, ({PlaybackState state, bool hasPrevious, bool hasNext})>(
      selector: (context, service) => (
        state: service.playbackState,
        hasPrevious: service.hasPrevious,
        hasNext: service.hasNext,
      ),
      builder: (context, controls, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.skip_previous),
              onPressed: controls.hasPrevious
                  ? () => context.read<AudioPlayerService>().previous()
                  : null,
            ),
            _buildPlayPauseButton(controls.state),
            IconButton(
              icon: const Icon(Icons.skip_next),
              onPressed: controls.hasNext
                  ? () => context.read<AudioPlayerService>().next()
                  : null,
            ),
          ],
        );
      },
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
  
