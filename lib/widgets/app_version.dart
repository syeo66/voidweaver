import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The installed app's version, e.g. "Voidweaver 1.1.0 (160)". The build
/// number is the commit count, see android/app/build.gradle.kts.
class AppVersion extends StatefulWidget {
  const AppVersion({super.key});

  @override
  State<AppVersion> createState() => _AppVersionState();
}

class _AppVersionState extends State<AppVersion> {
  // Created once, not in build(), so rebuilds don't query the platform again
  final Future<PackageInfo> _info = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: _info,
      builder: (context, snapshot) {
        final info = snapshot.data;
        if (info == null) return const SizedBox.shrink();
        return Text(
          'Voidweaver ${info.version} (${info.buildNumber})',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        );
      },
    );
  }
}
