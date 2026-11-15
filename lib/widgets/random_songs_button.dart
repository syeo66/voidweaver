import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/network_errors.dart';

/// Plays random songs (subsoxy's weighted pick), with a spinner while they're
/// fetched. Shows why in a snack bar if they can't be played.
class RandomSongsButton extends StatefulWidget {
  const RandomSongsButton({super.key});

  @override
  State<RandomSongsButton> createState() => _RandomSongsButtonState();
}

class _RandomSongsButtonState extends State<RandomSongsButton> {
  bool _starting = false;

  Future<void> _play() async {
    setState(() => _starting = true);

    final appState = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final errorColor = Theme.of(context).colorScheme.error;

    try {
      await appState.audioPlayerService?.playRandomSongs();
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              NetworkErrorHelper.getErrorMessage(
                e,
                context: 'Failed to play random songs',
              ),
            ),
            backgroundColor: errorColor,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: _starting
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.shuffle),
      tooltip: 'Play random songs',
      onPressed: _starting ? null : _play,
    );
  }
}
