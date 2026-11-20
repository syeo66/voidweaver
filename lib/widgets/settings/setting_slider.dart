import 'package:material_ui/material_ui.dart';

/// A setting's title and slider, which shows the value it is dragged to and
/// hands it to [onChanged] once, when the drag ends (also for a tap, a key
/// press or a screen reader's adjustment). Saving and applying a value on
/// every step of a drag would write the preferences, and for ReplayGain
/// update every item in the player, many times a second.
class SettingSlider extends StatefulWidget {
  /// The saved value.
  final double value;
  final double min;
  final double max;
  final int divisions;

  /// The value as the title and the slider's label show it, e.g. `3.5 dB`.
  final String Function(double value) format;

  /// The title before the formatted value, e.g. `Preamp`.
  final String title;

  final ValueChanged<double> onChanged;

  const SettingSlider({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    required this.onChanged,
  });

  @override
  State<SettingSlider> createState() => _SettingSliderState();
}

class _SettingSliderState extends State<SettingSlider> {
  /// The value dragged to, until the saved value changes: dropping it as the
  /// drag ends would show the old value until the setting has been saved.
  double? _value;

  @override
  void didUpdateWidget(SettingSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) _value = null;
  }

  @override
  Widget build(BuildContext context) {
    final value = (_value ?? widget.value).clamp(widget.min, widget.max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${widget.title}: ${widget.format(value)}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Slider(
          value: value,
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          label: widget.format(value),
          onChanged: (value) => setState(() => _value = value),
          onChangeEnd: (value) {
            setState(() => _value = value);
            if (value != widget.value) widget.onChanged(value);
          },
        ),
      ],
    );
  }
}
