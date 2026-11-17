import 'package:flutter/services.dart';

/// The app's launcher shortcut (long-press the app icon → Random), see
/// docs/ANDROID.md#launcher-shortcut. `MainActivity` notes a tap; the app
/// takes it once it's ready and whenever it comes to the front.
class LauncherShortcuts {
  LauncherShortcuts._();

  static const _channel = MethodChannel('voidweaver/shortcuts');

  /// Whether the Random shortcut was tapped since the last call: true once
  /// per tap. False without a handler (no activity has attached to the
  /// engine yet, or not on Android).
  static Future<bool> takeRandomRequest() async {
    try {
      return await _channel.invokeMethod<bool>('takeRandomRequest') ?? false;
    } on MissingPluginException {
      return false;
    }
  }
}
