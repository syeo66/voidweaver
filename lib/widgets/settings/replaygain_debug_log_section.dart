import 'package:flutter/material.dart';

import '../../services/replaygain_debug_logger.dart';
import '../../utils/format.dart';

/// Turning the ReplayGain debug log on and off, exporting and clearing it.
class ReplayGainDebugLogSection extends StatefulWidget {
  const ReplayGainDebugLogSection({super.key});

  @override
  State<ReplayGainDebugLogSection> createState() =>
      ReplayGainDebugLogSectionState();
}

class ReplayGainDebugLogSectionState extends State<ReplayGainDebugLogSection> {
  final ReplayGainDebugLogger _logger = ReplayGainDebugLogger.instance;
  final GlobalKey _exportButtonKey = GlobalKey();
  late Future<int> _sizeFuture;

  @override
  void initState() {
    super.initState();
    _sizeFuture = _logger.sizeBytes();
  }

  void _refreshSize() {
    setState(() {
      _sizeFuture = _logger.sizeBytes();
    });
  }

  Future<void> _handleExport() async {
    final renderBox =
        _exportButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final sharePositionOrigin = renderBox != null
        ? renderBox.localToGlobal(Offset.zero) & renderBox.size
        : null;

    final success = await _logger.exportLog(
      sharePositionOrigin: sharePositionOrigin,
    );
    if (!mounted) return;
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Log is empty — nothing to export yet'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _handleClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Debug Log?'),
        content: const Text(
          'This permanently deletes the stored ReplayGain debug log. This cannot be undone.',
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

    await _logger.clear();
    if (!mounted) return;
    _refreshSize();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Debug log cleared'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ReplayGain Debug Log',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              "If ReplayGain volume normalization isn't being applied to some "
              'songs, enable this to record diagnostic details for every '
              'track played: the stream URL, detected file format, where '
              'ReplayGain metadata was found (server response vs. reading '
              'the file directly), the parsed gain/peak values, current '
              'settings, and the resulting volume adjustment. Export the '
              'log and share it to help track down the issue.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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
                      'export and share this file with people you trust.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ListenableBuilder(
              listenable: _logger,
              builder: (context, _) {
                return SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enable Debug Logging'),
                  subtitle: const Text(
                    'Record ReplayGain diagnostics to a log file on this device',
                  ),
                  value: _logger.enabled,
                  onChanged: (value) async {
                    await _logger.setEnabled(value);
                    _refreshSize();
                  },
                );
              },
            ),
            const SizedBox(height: 8),
            FutureBuilder<int>(
              future: _sizeFuture,
              builder: (context, snapshot) {
                final size = snapshot.data ?? 0;
                return Text(
                  'Log size: ${formatBytes(size)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: _exportButtonKey,
                    onPressed: _handleExport,
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Export'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _handleClear,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Clear'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
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
