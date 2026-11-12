import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../screens/advanced_network_dialog.dart';
import '../../services/settings_service.dart';
import 'settings_snackbars.dart';

/// Network presets, the current timeouts, and the advanced dialog.
class NetworkSection extends StatelessWidget {
  final SettingsService settingsService;

  const NetworkSection({super.key, required this.settingsService});

  @override
  Widget build(BuildContext context) {
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
                        showSettingsSuccess(
                          context,
                          'Fast connection preset applied',
                        );
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
                        showSettingsSuccess(
                          context,
                          'Default connection preset applied',
                        );
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
                        showSettingsSuccess(
                          context,
                          'Slow connection preset applied',
                        );
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
                  _buildConfigRow(
                    'Connection Timeout',
                    '${settingsService.networkConfig.connectionTimeout.inSeconds}s',
                  ),
                  _buildConfigRow(
                    'Request Timeout',
                    '${settingsService.networkConfig.requestTimeout.inSeconds}s',
                  ),
                  _buildConfigRow(
                    'Max Retries',
                    '${settingsService.networkConfig.maxRetryAttempts}',
                  ),
                  _buildConfigRow(
                    'Retry on Timeout',
                    settingsService.networkConfig.enableRetryOnTimeout
                        ? 'Yes'
                        : 'No',
                  ),
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
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  void _showAdvancedNetworkSettings(
    BuildContext context,
    SettingsService settingsService,
  ) {
    unawaited(
      showDialog(
        context: context,
        builder: (context) =>
            AdvancedNetworkSettingsDialog(settingsService: settingsService),
      ),
    );
  }
}
