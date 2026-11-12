import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/settings_service.dart';
import '../services/app_state.dart';
import '../widgets/app_version.dart';
import '../widgets/settings/appearance_section.dart';
import '../widgets/settings/cache_section.dart';
import '../widgets/settings/network_section.dart';
import '../widgets/settings/replaygain_section.dart';
import '../widgets/settings/scrobbling_section.dart';
import '../widgets/settings/session_log_section.dart';

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
        // An explicit padding replaces ListView's automatic safe-area inset,
        // so add the system navigation bar's height back at the bottom.
        return ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            AppearanceSection(settingsService: settingsService),
            const SizedBox(height: 16),
            NetworkSection(settingsService: settingsService),
            const SizedBox(height: 16),
            const CacheSection(),
            const SizedBox(height: 16),
            ReplayGainSection(settingsService: settingsService),
            const SizedBox(height: 16),
            ScrobblingSection(settingsService: settingsService),
            const SizedBox(height: 16),
            const SessionLogSection(),
            const SizedBox(height: 24),
            const AppVersion(),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}
