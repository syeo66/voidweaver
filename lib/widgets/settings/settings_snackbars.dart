import 'package:material_ui/material_ui.dart';

/// Confirms a changed setting.
void showSettingsSuccess(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: Colors.green,
      duration: const Duration(seconds: 2),
    ),
  );
}
