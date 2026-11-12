import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../services/session_log.dart';
import '../../utils/format.dart';

/// Exporting and clearing the session log (this run of the app and the
/// previous one), see [SessionLog].
class SessionLogSection extends StatefulWidget {
  const SessionLogSection({super.key});

  @override
  State<SessionLogSection> createState() => _SessionLogSectionState();
}

class _SessionLogSectionState extends State<SessionLogSection> {
  final SessionLog _log = SessionLog.instance;
  final GlobalKey _exportButtonKey = GlobalKey();
  late Future<int> _previousSize;

  @override
  void initState() {
    super.initState();
    _previousSize = _log.previousSizeBytes();
  }

  void _refresh() {
    setState(() {
      _previousSize = _log.previousSizeBytes();
    });
  }

  Future<void> _export() async {
    final box =
        _exportButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final origin = box != null
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    final shared = await _log.export(sharePositionOrigin: origin);
    if (!mounted) return;
    _refresh();
    if (!shared) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nothing to export'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Session Log?'),
        content: const Text(
          'This deletes the log of this run and of the previous one.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _log.clear();
    if (!mounted) return;
    _refresh();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Session log cleared'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Session Log', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'The app records what it does while it runs: playback, '
              'network errors, downloads, scrobbles and ReplayGain. If '
              'something goes wrong, export the log and share it to help '
              'track down the issue. It holds this run of the app and the '
              'previous one; older runs are discarded.',
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withAlpha(25),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withAlpha(76)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.privacy_tip_outlined,
                    color: Colors.orange,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'The log includes your server address and song details. '
                      'Login credentials are redacted before saving, but only '
                      'share it with people you trust.',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FutureBuilder<int>(
              future: _previousSize,
              builder: (context, snapshot) {
                final previous = snapshot.data ?? 0;
                return Text(
                  'This run: ${formatBytes(_log.sizeBytes)}'
                  '${previous > 0 ? ' · Previous run: ${formatBytes(previous)}' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                );
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: _exportButtonKey,
                    onPressed: () => unawaited(_export()),
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Export'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => unawaited(_clear()),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Clear'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
