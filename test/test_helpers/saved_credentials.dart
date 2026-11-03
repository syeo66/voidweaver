import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:voidweaver/services/app_state.dart';

/// Secure storage contents with credentials as [AppState] saves them, for
/// [FlutterSecureStorage.setMockInitialValues].
Map<String, String> savedCredentials(
        String serverUrl, String username, String password) =>
    {
      AppState.credentialsKey: jsonEncode({
        'serverUrl': serverUrl,
        'username': username,
        'password': password,
      }),
    };

/// The credentials [AppState] saved in secure storage, as `serverUrl`,
/// `username` and `password`; null if there are none.
Future<Map<String, dynamic>?> readSavedCredentials() async {
  final json =
      await const FlutterSecureStorage().read(key: AppState.credentialsKey);
  return json == null ? null : jsonDecode(json) as Map<String, dynamic>;
}
