import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../services/settings_service.dart';
import 'setting_slider.dart';

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

            SettingSlider(
              title: 'Minimum Play Time',
              value: settingsService.scrobbleMinPlayTimeMinutes,
              min: 0.5,
              max: 10.0,
              divisions: 19,
              format: (value) => '${value.toStringAsFixed(1)} min',
              onChanged: (value) => unawaited(
                settingsService.setScrobbleMinPlayTimeMinutes(value),
              ),
            ),
            Text(
              'Scrobble once a song has played for this long',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),

            const SizedBox(height: 16),

            SettingSlider(
              title: 'Threshold',
              value: settingsService.scrobbleThresholdPercent,
              min: 10.0,
              max: 100.0,
              divisions: 90,
              format: (value) => '${value.round()}%',
              onChanged: (value) =>
                  unawaited(settingsService.setScrobbleThresholdPercent(value)),
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
