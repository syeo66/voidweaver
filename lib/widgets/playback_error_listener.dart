import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../services/audio_player_service.dart';

/// Shows [AudioPlayerService.playbackErrors] of [player] as snack bars, on
/// whatever screen is showing. A message replaces the snack bars before it:
/// only the latest failure says why playback stopped. While the app is
/// hidden, the message waits until it's shown again.
class PlaybackErrorListener extends StatefulWidget {
  final AudioPlayerService? player;
  final Widget child;

  const PlaybackErrorListener({
    super.key,
    required this.player,
    required this.child,
  });

  @override
  State<PlaybackErrorListener> createState() => _PlaybackErrorListenerState();
}

class _PlaybackErrorListenerState extends State<PlaybackErrorListener> {
  StreamSubscription<String>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(PlaybackErrorListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) {
      unawaited(_subscription?.cancel());
      _subscribe();
    }
  }

  void _subscribe() {
    _subscription = widget.player?.playbackErrors.listen(_show);
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
