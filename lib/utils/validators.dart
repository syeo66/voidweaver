class Validators {
  static String? validateServerUrl(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Server URL is required';
    }

    final trimmed = value.trim();

    if (trimmed.length > 2048) {
      return 'Server URL is too long';
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.isAbsolute) {
      return 'Please enter a valid URL (e.g., https://music.example.com)';
    }

    if (uri.scheme.toLowerCase() != 'https') {
      return 'URL must use HTTPS protocol for security';
    }

    if (uri.host.isEmpty) {
      return 'URL must include a hostname';
    }

    return null;
  }

  static String? validateUsername(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Username is required';
    }

    final trimmed = value.trim();

    if (trimmed.isEmpty) {
      return 'Username cannot be empty';
    }

    if (trimmed.length > 100) {
      return 'Username is too long (max 100 characters)';
    }

    if (trimmed.contains('\n') ||
        trimmed.contains('\r') ||
        trimmed.contains('\t')) {
      return 'Username contains invalid characters';
    }

    return null;
  }

  static String? validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Password is required';
    }

    if (value.length > 256) {
      return 'Password is too long (max 256 characters)';
    }

    if (value.contains('\n') || value.contains('\r') || value.contains('\t')) {
      return 'Password contains invalid characters';
    }

    return null;
  }

  /// The server URL as the app stores and uses it: sanitized, without
  /// trailing slashes, so request paths and cache keys don't depend on how
  /// it was typed (`https://host/` would request `https://host//rest/...`).
  static String normalizeServerUrl(String? input) {
    var url = sanitizeInput(input);
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  static String sanitizeInput(String? input) {
    if (input == null) return '';

    return input
        .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '')
        .replaceAll(RegExp(r'[\n\r\t]'), ' ')
        .trim();
  }
}
