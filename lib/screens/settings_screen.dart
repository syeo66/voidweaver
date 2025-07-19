import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../services/app_state.dart';
import '../utils/validators.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Consumer<AppState>(
        builder: (context, appState, child) {
          final settingsService = appState.settingsService;
          if (settingsService == null) {
            return const Center(child: CircularProgressIndicator());
          }

          return ChangeNotifierProvider.value(
            value: settingsService,
            child: const _SettingsContent(),
          );
        },
      ),
    );
  }
}

class _SettingsContent extends StatelessWidget {
  const _SettingsContent();

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsService>(
      builder: (context, settingsService, child) {
        return ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            _buildAppearanceSection(context, settingsService),
            const SizedBox(height: 16),
            _buildReplayGainSection(context, settingsService),
          ],
        );
      },
    );
  }

  Widget _buildAppearanceSection(
      BuildContext context, SettingsService settingsService) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Appearance',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),

            // Theme Mode
            Text(
              'Theme',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Column(
              children: ThemeMode.values.map((mode) {
                return RadioListTile<ThemeMode>(
                  title: Text(_getThemeModeTitle(mode)),
                  subtitle: Text(_getThemeModeDescription(mode)),
                  value: mode,
                  groupValue: settingsService.themeMode,
                  onChanged: (ThemeMode? value) {
                    if (value != null) {
                      settingsService.setThemeMode(value);
                    }
                  },
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReplayGainSection(
      BuildContext context, SettingsService settingsService) {
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
                    color: Colors.grey[600],
                  ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_outline,
                      color: Colors.green, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'ReplayGain metadata is read directly from your audio files for accurate volume normalization.',
                      style: TextStyle(fontSize: 12, color: Colors.green[800]),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ReplayGain Mode
            Text(
              'Mode',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Column(
              children: ReplayGainMode.values.map((mode) {
                return RadioListTile<ReplayGainMode>(
                  title: Text(_getReplayGainModeTitle(mode)),
                  subtitle: Text(_getReplayGainModeDescription(mode)),
                  value: mode,
                  groupValue: settingsService.replayGainMode,
                  onChanged: (ReplayGainMode? value) {
                    if (value != null) {
                      settingsService.setReplayGainMode(value);
                      _refreshAudioVolume(context);
                    }
                  },
                );
              }).toList(),
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
                  final validationError =
                      Validators.validateReplayGainPreamp(value);
                  if (validationError == null) {
                    settingsService.setReplayGainPreamp(value);
                    _refreshAudioVolume(context);
                  } else {
                    _showValidationError(context, validationError);
                  }
                },
              ),
              Text(
                'Adjust the overall volume level',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                    ),
              ),

              const SizedBox(height: 16),

              // Prevent Clipping
              SwitchListTile(
                title: const Text('Prevent Clipping'),
                subtitle:
                    const Text('Reduce volume to prevent audio distortion'),
                value: settingsService.replayGainPreventClipping,
                onChanged: (value) {
                  settingsService.setReplayGainPreventClipping(value);
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
                    settingsService.setReplayGainFallbackGain(value);
                    _refreshAudioVolume(context);
                  } else {
                    _showValidationError(context, validationError);
                  }
                },
              ),
              Text(
                'Gain applied to songs without ReplayGain data',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
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
    }
  }

  String _getThemeModeTitle(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'System';
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
    }
  }

  String _getThemeModeDescription(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'Follow system theme settings';
      case ThemeMode.light:
        return 'Always use light theme';
      case ThemeMode.dark:
        return 'Always use dark theme';
    }
  }

  void _refreshAudioVolume(BuildContext context) {
    final appState = context.read<AppState>();
    final audioPlayer = appState.audioPlayerService;
    if (audioPlayer != null) {
      audioPlayer.refreshReplayGainVolume();
    }
  }

  void _showValidationError(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
      ),
    );
  }
}
