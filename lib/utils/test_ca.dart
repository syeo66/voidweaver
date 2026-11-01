import 'dart:convert';
import 'dart:io';

/// A CA certificate (PEM, base64-encoded) that the app's HTTP clients trust
/// in addition to the system's, set with
/// `--dart-define=VOIDWEAVER_TEST_CA=...`. Only `tool/emulator_check.sh
/// --fake-server` sets it, for a release build that logs into the fake
/// Subsonic server of the tests; the native player trusts it through that
/// build's network security config. Empty in every other build, which then
/// contains none of this.
const testCa = String.fromEnvironment('VOIDWEAVER_TEST_CA');

/// Trusts [testCa], if set, in every [HttpClient] created from now on.
void trustTestCa() {
  if (testCa.isEmpty) return;
  HttpOverrides.global = _TrustTestCa(base64Decode(testCa));
}

class _TrustTestCa extends HttpOverrides {
  final List<int> _ca;

  _TrustTestCa(this._ca);

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificatesBytes(_ca));
}
