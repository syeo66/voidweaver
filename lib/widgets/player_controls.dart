import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/audio_player_service.dart';

class PlayerControls extends StatelessWidget {
  const PlayerControls({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AudioPlayerService>(
      builder: (context, playerService, child) {
        if (playerService.currentSong == null) {
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildProgressBar(playerService),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            playerService.currentSong!.title,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            playerService.currentSong!.artist,
                            style: TextStyle(color: Colors.grey[600]),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    _buildControlButtons(playerService),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
  
  Widget _buildProgressBar(AudioPlayerService playerService) {
    return SizedBox(
      height: 4,
      child: LinearProgressIndicator(
        value: playerService.totalDuration.inMilliseconds > 0
            ? playerService.currentPosition.inMilliseconds / playerService.totalDuration.inMilliseconds
            : 0,
        backgroundColor: Colors.grey[300],
        valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
      ),
    );
  }
  
  Widget _buildControlButtons(AudioPlayerService playerService) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.skip_previous),
          onPressed: playerService.hasPrevious ? () => playerService.previous() : null,
        ),
        _buildPlayPauseButton(playerService),
        IconButton(
          icon: const Icon(Icons.skip_next),
          onPressed: playerService.hasNext ? () => playerService.next() : null,
        ),
      ],
    );
  }
  
  Widget _buildPlayPauseButton(AudioPlayerService playerService) {
    switch (playerService.playbackState) {
      case PlaybackState.playing:
        return IconButton(
          icon: const Icon(Icons.pause),
          onPressed: () => playerService.pause(),
        );
      case PlaybackState.paused:
      case PlaybackState.stopped:
        return IconButton(
          icon: const Icon(Icons.play_arrow),
          onPressed: () => playerService.play(),
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
  }
}