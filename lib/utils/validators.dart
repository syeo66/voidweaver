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

    if (!['http', 'https'].contains(uri.scheme.toLowerCase())) {
      return 'URL must use http or https protocol';
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

  static String? validateReplayGainPreamp(double? value) {
    if (value == null) {
      return 'Preamp value is required';
    }

    if (value.isNaN || value.isInfinite) {
      return 'Invalid preamp value';
    }

    if (value < -15.0) {
      return 'Preamp cannot be less than -15.0 dB';
    }

    if (value > 15.0) {
      return 'Preamp cannot be greater than 15.0 dB';
    }

    return null;
  }

  static String? validateReplayGainFallbackGain(double? value) {
    if (value == null) {
      return 'Fallback gain value is required';
    }

    if (value.isNaN || value.isInfinite) {
      return 'Invalid fallback gain value';
    }

    if (value < -15.0) {
      return 'Fallback gain cannot be less than -15.0 dB';
    }

    if (value > 15.0) {
      return 'Fallback gain cannot be greater than 15.0 dB';
    }

    return null;
  }

  static bool isValidUrl(String? url) {
    if (url == null || url.trim().isEmpty) return false;

    final uri = Uri.tryParse(url.trim());
    return uri != null &&
        uri.isAbsolute &&
        ['http', 'https'].contains(uri.scheme.toLowerCase()) &&
        uri.host.isNotEmpty;
  }

  static String sanitizeInput(String? input) {
    if (input == null) return '';

    return input
        .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '')
        .replaceAll(RegExp(r'[\n\r\t]'), ' ')
        .trim();
  }

  static String? validateNonEmpty(String? value, String fieldName) {
    if (value == null || value.trim().isEmpty) {
      return '$fieldName is required';
    }
    return null;
  }

  static String? validateLength(
      String? value, int maxLength, String fieldName) {
    if (value != null && value.length > maxLength) {
      return '$fieldName is too long (max $maxLength characters)';
    }
    return null;
  }

  static String? validateRange(
      double? value, double min, double max, String fieldName) {
    if (value == null) {
      return '$fieldName is required';
    }

    if (value.isNaN || value.isInfinite) {
      return 'Invalid $fieldName value';
    }

    if (value < min) {
      return '$fieldName cannot be less than $min';
    }

    if (value > max) {
      return '$fieldName cannot be greater than $max';
    }

    return null;
  }
}
