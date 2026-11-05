import 'dart:async';

import 'package:flutter/material.dart';

import '../services/audio_player_service.dart';
import '../utils/format.dart';

/// Shows the [SleepTimerDialog] for [playerService].
Future<void> showSleepTimerDialog(
  BuildContext context,
  AudioPlayerService playerService,
) => showDialog<void>(
  context: context,
  builder: (context) => SleepTimerDialog(playerService: playerService),
);

/// Starts a sleep timer from presets, or shows the running one's remaining
/// time with buttons to extend or cancel it.
class SleepTimerDialog extends StatefulWidget {
  final AudioPlayerService playerService;

  const SleepTimerDialog({super.key, required this.playerService});

  @override
  State<SleepTimerDialog> createState() => SleepTimerDialogState2();
}

class SleepTimerDialogState2 extends State<SleepTimerDialog> {
  static const List<Duration> _presetDurations = [
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(minutes: 45),
    Duration(minutes: 60),
    Duration(minutes: 90),
    Duration(minutes: 120),
  ];

  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    // Update remaining time every second
    _updateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Sleep Timer'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.playerService.isSleepTimerActive) ...[
            const Text('Timer Active'),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: Column(
                children: [
                  const Icon(Icons.bedtime, color: Colors.orange, size: 32),
                  const SizedBox(height: 8),
                  Text(
                    'Time remaining:',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    formatClock(
                      widget.playerService.sleepTimerRemaining ?? Duration.zero,
                    ),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.orange,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('+15m'),
                  onPressed: () {
                    widget.playerService.extendSleepTimer(
                      const Duration(minutes: 15),
                    );
                  },
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.cancel),
                  label: const Text('Cancel'),
                  onPressed: () {
                    widget.playerService.cancelSleepTimer();
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ),
          ] else ...[
            const Text('Set sleep timer duration:'),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _presetDurations.map((duration) {
                return ElevatedButton(
                  onPressed: () {
                    widget.playerService.startSleepTimer(duration);
                    Navigator.of(context).pop();
                  },
                  child: Text(formatHoursMinutes(duration)),
                );
              }).toList(),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
