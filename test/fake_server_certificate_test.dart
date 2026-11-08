import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'test_helpers/fake_server_certificate.dart';
import 'test_helpers/fake_subsonic_server.dart';

/// The fake Subsonic server's certificate is valid for 825 days (see
/// tool/fake_server_cert.sh). Once it expires, the integration tests, the
/// host tests over HTTPS and tool/emulator_check.sh --fake-server fail with
/// a handshake error; this fails ahead of that, with what to do.
void main() {
  const warning = Duration(days: 60);

  test('the fake server\'s certificate is not about to expire', () async {
    final server = FakeSubsonicServer();
    await server.start();
    addTearDown(server.close);
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(utf8.encode(fakeServerCa)),
    );
    addTearDown(client.close);

    // The certificate as clients see it, which also checks the CA signed it
    final request = await client.getUrl(Uri.parse('${server.url}/rest/ping'));
    final response = await request.close();
    await response.drain<void>();
    final expires = response.certificate!.endValidity;

    expect(
      expires.difference(DateTime.now()),
      greaterThan(warning),
      reason:
          'The fake server\'s certificate expires on $expires. '
          'Run tool/fake_server_cert.sh to make a new one.',
    );
  });
}
