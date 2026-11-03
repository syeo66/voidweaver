import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/settings_service.dart';

/// Theme mode.
class AppearanceSection extends StatelessWidget {
  final SettingsService settingsService;

  const AppearanceSection({super.key, required this.settingsService});

  @override
  Widget build(BuildContext context) {
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
            RadioGroup<ThemeMode>(
              groupValue: settingsService.themeMode,
              onChanged: (ThemeMode? value) {
                if (value != null) {
                  unawaited(settingsService.setThemeMode(value));
                }
              },
              child: Column(
                children: ThemeMode.values.map((mode) {
                  return ListTile(
                    title: Text(_getThemeModeTitle(mode)),
                    subtitle: Text(_getThemeModeDescription(mode)),
                    leading: Radio<ThemeMode>(value: mode),
                    onTap: () {
                      unawaited(settingsService.setThemeMode(mode));
                    },
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
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
}
