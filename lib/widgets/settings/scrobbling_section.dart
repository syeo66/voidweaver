import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/settings_service.dart';
import '../../utils/validators.dart';
import 'settings_snackbars.dart';

/// Scrobble threshold: minimum play time and percentage.
class ScrobblingSection extends StatelessWidget {
  final SettingsService settingsService;

  const ScrobblingSection({super.key, required this.settingsService});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Scrobbling',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'A song is scrobbled once it has played for the minimum time '
              'or reached the percentage threshold below, whichever comes first.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),

            // Minimum play time
            Text(
              'Minimum Play Time: ${settingsService.scrobbleMinPlayTimeMinutes.toStringAsFixed(1)} min',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Slider(
              value: settingsService.scrobbleMinPlayTimeMinutes,
              min: 0.5,
              max: 10.0,
              divisions: 19,
              label:
                  '${settingsService.scrobbleMinPlayTimeMinutes.toStringAsFixed(1)} min',
              onChanged: (value) {
                final validationError =
                    Validators.validateScrobbleMinPlayTimeMinutes(value);
                if (validationError == null) {
                  unawaited(
                      settingsService.setScrobbleMinPlayTimeMinutes(value));
                } else {
                  showSettingsError(context, validationError);
                }
              },
            ),
            Text(
              'Scrobble once a song has played for this long',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),

            const SizedBox(height: 16),

            // Threshold percent
            Text(
              'Threshold: ${settingsService.scrobbleThresholdPercent.round()}%',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Slider(
              value: settingsService.scrobbleThresholdPercent,
              min: 10.0,
              max: 100.0,
              divisions: 90,
              label: '${settingsService.scrobbleThresholdPercent.round()}%',
              onChanged: (value) {
                final validationError =
                    Validators.validateScrobbleThresholdPercent(value);
                if (validationError == null) {
                  unawaited(settingsService.setScrobbleThresholdPercent(value));
                } else {
                  showSettingsError(context, validationError);
                }
              },
            ),
            Text(
              'Scrobble once this percentage of a song has played',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
