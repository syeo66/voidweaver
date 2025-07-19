import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';

class SyncStatusIndicator extends StatelessWidget {
  const SyncStatusIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        final syncStatus = appState.syncStatus;
        final lastSyncTime = appState.lastSyncTime;

        Widget icon;
        Color color;
        String tooltip;

        switch (syncStatus) {
          case SyncStatus.idle:
            icon = const Icon(Icons.sync, size: 16);
            color = Colors.grey;
            tooltip = lastSyncTime != null
                ? 'Last sync: ${_formatTime(lastSyncTime)}'
                : 'Sync idle';
            break;
          case SyncStatus.syncing:
            icon = const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
              ),
            );
            color = Colors.blue;
            tooltip = 'Syncing...';
            break;
          case SyncStatus.success:
            icon = const Icon(Icons.check_circle, size: 16);
            color = Colors.green;
            tooltip = 'Sync successful';
            break;
          case SyncStatus.error:
            icon = const Icon(Icons.error, size: 16);
            color = Colors.red;
            tooltip = 'Sync failed';
            break;
        }

        return Tooltip(
          message: tooltip,
          child: Container(
            padding: const EdgeInsets.all(8),
            child: IconTheme(
              data: IconThemeData(color: color),
              child: icon,
            ),
          ),
        );
      },
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) {
      return 'Just now';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else {
      return '${diff.inDays}d ago';
    }
  }
}
