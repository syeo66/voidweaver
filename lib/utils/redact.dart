final _authParamPattern = RegExp(r'([?&](?:u|p|t|s)=)[^&\s#,]*');

/// Masks Subsonic auth query parameters (username, password, token, salt)
/// anywhere in [text]. Unlike [ReplayGainDebugLogger.redact], this works on
/// arbitrary strings, e.g. exception messages that embed a request URL.
String redactCredentials(String text) =>
    text.replaceAllMapped(_authParamPattern, (m) => '${m[1]}[REDACTED]');
