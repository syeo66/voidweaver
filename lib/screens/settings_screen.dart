import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../services/app_state.dart';
import '../utils/validators.dart';
import 'advanced_network_dialog.dart';

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
            _buildNetworkSection(context, settingsService),
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
                color: Colors.green.withAlpha(25),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.withAlpha(76)),
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

  Widget _buildNetworkSection(
      BuildContext context, SettingsService settingsService) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Network & Timeouts',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),

            // Preset configurations
            Text(
              'Connection Preset',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      await settingsService.setNetworkConfigToFast();
                      if (context.mounted) {
                        _showNetworkConfigSuccess(
                            context, 'Fast connection preset applied');
                      }
                    },
                    child: const Text('Fast'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      await settingsService.resetNetworkConfigToDefault();
                      if (context.mounted) {
                        _showNetworkConfigSuccess(
                            context, 'Default connection preset applied');
                      }
                    },
                    child: const Text('Default'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      await settingsService.setNetworkConfigToSlow();
                      if (context.mounted) {
                        _showNetworkConfigSuccess(
                            context, 'Slow connection preset applied');
                      }
                    },
                    child: const Text('Slow'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Current configuration display
            Text(
              'Current Configuration',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline.withAlpha(76),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildConfigRow('Connection Timeout',
                      '${settingsService.networkConfig.connectionTimeout.inSeconds}s'),
                  _buildConfigRow('Request Timeout',
                      '${settingsService.networkConfig.requestTimeout.inSeconds}s'),
                  _buildConfigRow('Max Retries',
                      '${settingsService.networkConfig.maxRetryAttempts}'),
                  _buildConfigRow(
                      'Retry on Timeout',
                      settingsService.networkConfig.enableRetryOnTimeout
                          ? 'Yes'
                          : 'No'),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Advanced settings button
            Center(
              child: TextButton.icon(
                onPressed: () {
                  _showAdvancedNetworkSettings(context, settingsService);
                },
                icon: const Icon(Icons.settings),
                label: const Text('Advanced Settings'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfigRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  void _showAdvancedNetworkSettings(
      BuildContext context, SettingsService settingsService) {
    showDialog(
      context: context,
      builder: (context) => AdvancedNetworkSettingsDialog(
        settingsService: settingsService,
      ),
    );
  }

  void _showNetworkConfigSuccess(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
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
