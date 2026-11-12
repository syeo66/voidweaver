import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../services/app_state.dart';
import '../../services/settings_service.dart';
import '../../utils/validators.dart';
import 'settings_snackbars.dart';

/// ReplayGain mode, preamp, clipping prevention and fallback gain. Changes
/// apply to the queue right away.
class ReplayGainSection extends StatelessWidget {
  final SettingsService settingsService;

  const ReplayGainSection({super.key, required this.settingsService});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ReplayGain',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Normalize volume levels for consistent playback',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.withAlpha(25),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.withAlpha(76)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.check_circle_outline,
                    color: Colors.green,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'ReplayGain metadata is read directly from your audio files for accurate volume normalization.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ReplayGain Mode
            Text('Mode', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            RadioGroup<ReplayGainMode>(
              groupValue: settingsService.replayGainMode,
              onChanged: (ReplayGainMode? value) {
                if (value != null) {
                  unawaited(settingsService.setReplayGainMode(value));
                  _refreshAudioVolume(context);
                }
              },
              child: Column(
                children: ReplayGainMode.values.map((mode) {
                  return ListTile(
                    title: Text(_getReplayGainModeTitle(mode)),
                    subtitle: Text(_getReplayGainModeDescription(mode)),
                    leading: Radio<ReplayGainMode>(value: mode),
                    onTap: () {
                      unawaited(settingsService.setReplayGainMode(mode));
                      _refreshAudioVolume(context);
                    },
                  );
                }).toList(),
              ),
            ),

            if (settingsService.replayGainMode != ReplayGainMode.off) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 16),

              // Preamp
              Text(
                'Preamp: ${settingsService.replayGainPreamp.toStringAsFixed(1)} dB',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Slider(
                value: settingsService.replayGainPreamp,
                min: -15.0,
                max: 15.0,
                divisions: 300,
                label:
                    '${settingsService.replayGainPreamp.toStringAsFixed(1)} dB',
                onChanged: (value) {
                  final validationError = Validators.validateReplayGainPreamp(
                    value,
                  );
                  if (validationError == null) {
                    unawaited(settingsService.setReplayGainPreamp(value));
                    _refreshAudioVolume(context);
                  } else {
                    showSettingsError(context, validationError);
                  }
                },
              ),
              Text(
                'Adjust the overall volume level',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),

              const SizedBox(height: 16),

              // Prevent Clipping
              SwitchListTile(
                title: const Text('Prevent Clipping'),
                subtitle: const Text(
                  'Reduce volume to prevent audio distortion',
                ),
                value: settingsService.replayGainPreventClipping,
                onChanged: (value) {
                  unawaited(
                    settingsService.setReplayGainPreventClipping(value),
                  );
                  _refreshAudioVolume(context);
                },
              ),

              const SizedBox(height: 16),

              // Fallback Gain
              Text(
                'Fallback Gain: ${settingsService.replayGainFallbackGain.toStringAsFixed(1)} dB',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Slider(
                value: settingsService.replayGainFallbackGain,
                min: -15.0,
                max: 15.0,
                divisions: 300,
                label:
                    '${settingsService.replayGainFallbackGain.toStringAsFixed(1)} dB',
                onChanged: (value) {
                  final validationError =
                      Validators.validateReplayGainFallbackGain(value);
                  if (validationError == null) {
                    unawaited(settingsService.setReplayGainFallbackGain(value));
                    _refreshAudioVolume(context);
                  } else {
                    showSettingsError(context, validationError);
                  }
                },
              ),
              Text(
                'Gain applied to songs without ReplayGain data',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _getReplayGainModeTitle(ReplayGainMode mode) {
    switch (mode) {
      case ReplayGainMode.off:
        return 'Off';
      case ReplayGainMode.track:
        return 'Track';
      case ReplayGainMode.album:
        return 'Album';
      case ReplayGainMode.smart:
        return 'Smart';
    }
  }

  String _getReplayGainModeDescription(ReplayGainMode mode) {
    switch (mode) {
      case ReplayGainMode.off:
        return 'Disable ReplayGain volume normalization';
      case ReplayGainMode.track:
        return 'Normalize each track individually';
      case ReplayGainMode.album:
        return 'Normalize based on album levels';
      case ReplayGainMode.smart:
        return 'Album levels when playing an album, track levels otherwise';
    }
  }

  void _refreshAudioVolume(BuildContext context) {
    final appState = context.read<AppState>();
    final audioPlayer = appState.audioPlayerService;
    if (audioPlayer != null) {
      unawaited(audioPlayer.refreshReplayGainVolume());
    }
  }
}
