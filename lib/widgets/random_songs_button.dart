import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/network_errors.dart';

/// Plays random songs (subsoxy's weighted pick), showing why in a snack bar
/// if they can't be played, unless the widget behind [context] is gone by
/// then (e.g. logged out meanwhile). Does nothing when logged out.
Future<void> playRandomWithFeedback(BuildContext context) async {
  final player = context.read<AppState>().audioPlayerService;
  if (player == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final errorColor = Theme.of(context).colorScheme.error;
  try {
    await player.playRandomSongs();
  } catch (e) {
    if (context.mounted) {
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
  }
}

/// Plays random songs, with a spinner while they're fetched, see
/// [playRandomWithFeedback].
class RandomSongsButton extends StatefulWidget {
  const RandomSongsButton({super.key});

  @override
  State<RandomSongsButton> createState() => _RandomSongsButtonState();
}

class _RandomSongsButtonState extends State<RandomSongsButton> {
  bool _starting = false;

  Future<void> _play() async {
    setState(() => _starting = true);
    try {
      await playRandomWithFeedback(context);
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
