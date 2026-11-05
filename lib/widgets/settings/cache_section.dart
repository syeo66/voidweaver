import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_state.dart';
import '../../services/network_errors.dart';
import '../../utils/format.dart';

/// Size of the downloaded songs, and clearing all caches.
class CacheSection extends StatefulWidget {
  const CacheSection({super.key});

  @override
  State<CacheSection> createState() => CacheSectionState();
}

class CacheSectionState extends State<CacheSection> {
  late Future<int> _sizeFuture;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _sizeFuture = _loadSize();
  }

  Future<int> _loadSize() async {
    final playerService = context.read<AppState>().audioPlayerService;
    return await playerService?.audioCacheSize() ?? 0;
  }

  Future<void> _handleClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Cache?'),
        content: const Text(
          'This deletes downloaded songs, saved album and artist lists, and '
          'cover art. They will be downloaded again as needed, but won\'t '
          'be available offline until then.',
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

    if (confirmed != true || !mounted) return;

    setState(() => _clearing = true);
    try {
      await context.read<AppState>().clearCaches();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cache cleared'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            NetworkErrorHelper.getErrorMessage(
              e,
              context: 'Failed to clear cache',
            ),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _clearing = false;
          _sizeFuture = _loadSize();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Cache', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Upcoming songs are downloaded so playback continues offline. '
              'Album lists and cover art are also kept for offline browsing.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            FutureBuilder<int>(
              future: _sizeFuture,
              builder: (context, snapshot) {
                final size = snapshot.data;
                return Text(
                  size == null
                      ? 'Downloaded songs: calculating…'
                      : 'Downloaded songs: ${formatBytes(size)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _clearing ? null : _handleClear,
                icon: _clearing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_outline),
                label: const Text('Clear Cache'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
