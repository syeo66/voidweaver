import 'package:mockito/mockito.dart';

import 'mocks.mocks.dart';

/// A [MockSubsonicApi] whose credentials the server accepts. The player and
/// the scrobble queue ask for that before every request they make on their
/// own (see `SubsonicApi.hasRejectedCredentials`), so nearly every test needs
/// the stub; tests of rejected credentials stub it again.
MockSubsonicApi newMockApi() {
  final api = MockSubsonicApi();
  when(api.hasRejectedCredentials).thenReturn(false);
  return api;
}
