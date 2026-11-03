import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../services/app_state.dart';
import '../widgets/app_version.dart';
import '../widgets/settings/appearance_section.dart';
import '../widgets/settings/cache_section.dart';
import '../widgets/settings/network_section.dart';
import '../widgets/settings/replaygain_debug_log_section.dart';
import '../widgets/settings/replaygain_section.dart';
import '../widgets/settings/scrobbling_section.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: const BackButton(),
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
            AppearanceSection(settingsService: settingsService),
            const SizedBox(height: 16),
            NetworkSection(settingsService: settingsService),
            const SizedBox(height: 16),
            const CacheSection(),
            const SizedBox(height: 16),
            ReplayGainSection(settingsService: settingsService),
            const SizedBox(height: 16),
            const ReplayGainDebugLogSection(),
            const SizedBox(height: 16),
            ScrobblingSection(settingsService: settingsService),
            const SizedBox(height: 24),
            const AppVersion(),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}
