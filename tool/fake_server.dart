// Runs the fake Subsonic server of the tests (test/test_helpers/
// fake_subsonic_server.dart) on the host until it's stopped, for
// tool/emulator_check.sh --fake-server. The emulator reaches it as
// https://localhost:<port> through `adb reverse`.
//
//   dart run tool/fake_server.dart [port]   # default 8443
//
// Its songs are a minute long, unlike the tests' four seconds: the checks
// need time within a track (Previous within its first seconds goes back a
// track, the seek near the end).

import 'dart:async';
import 'dart:io';

import '../test/test_helpers/fake_subsonic_server.dart';

const _length = Duration(minutes: 1);

Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 8443 : int.parse(args.first);
  final server = FakeSubsonicServer(
    albums: [
      for (final album in FakeSubsonicServer.defaultAlbums)
        FakeAlbum(album.id, album.name, album.artist, [
          for (final song in album.songs)
            FakeSong(song.id, song.title, length: _length),
        ]),
    ],
  );
  await server.start(port: port);
  // tool/emulator_check.sh waits for this line
  stdout.writeln(
    'Fake Subsonic server at ${server.url} '
    '(user ${server.username}, password ${server.password})',
  );

  final stop = Completer<void>();
  final signals = [
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm])
      signal.watch().listen((_) {
        if (!stop.isCompleted) stop.complete();
      }),
  ];
  await stop.future;
  // Otherwise they keep the process running
  for (final subscription in signals) {
    await subscription.cancel();
  }
  await server.close();
  stdout.writeln('Scrobbles received: ${server.scrobbles}');
}
