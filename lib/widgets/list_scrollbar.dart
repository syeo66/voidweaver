import 'package:material_ui/material_ui.dart';

/// A draggable scrollbar around a long list (the whole library, every
/// artist): its thumb can be grabbed to jump through thousands of entries,
/// which swiping alone makes tedious. Appears while scrolling.
///
/// Owns the [ScrollController] that [builder] must give its list. Not the
/// primary one: the home screen keeps several lists alive at once
/// (`IndexedStack`), which would share it.
class ListScrollbar extends StatefulWidget {
  const ListScrollbar({super.key, required this.builder});

  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  @override
  State<ListScrollbar> createState() => _ListScrollbarState();
}

class _ListScrollbarState extends State<ListScrollbar> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      interactive: true,
      child: widget.builder(context, _controller),
    );
  }
}
