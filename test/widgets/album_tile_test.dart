import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:voidweaver/services/app_state.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/network_errors.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:voidweaver/widgets/album_tile.dart';

/// Records the albums played; each play finishes when [result] does.
class _FakePlayer extends Fake implements AudioPlayerService {
  final played = <Album>[];

  // Created on first use, inside the test: a future belongs to the zone it
  // was created in, and one from setUp() would complete outside the test's
  // fake async zone, after the test
  late final result = Completer<void>();

  @override
  Future<void> playAlbum(Album album) {
    played.add(album);
    return result.future;
  }
}

/// An [AppState] with the given player and no API (no cover art)
class _FakeAppState extends AppState {
  final AudioPlayerService? _player;

  _FakeAppState(this._player);

  @override
  AudioPlayerService? get audioPlayerService => _player;
}

void main() {
  final album = Album(
    id: 'al-1',
    name: 'Some Album',
    artist: 'Some Artist',
    songCount: 9,
    duration: 3725,
  );

  late _FakePlayer player;

  setUp(() => player = _FakePlayer());

  // Grid tile size by default; a list tile is as wide as the screen
  Future<void> pump(WidgetTester tester, Widget tile,
          {AudioPlayerService? withPlayer, Size size = const Size(200, 260)}) =>
      tester.pumpWidget(ChangeNotifierProvider<AppState>(
        create: (_) => _FakeAppState(withPlayer ?? player),
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(size: size, child: tile),
            ),
          ),
        ),
      ));

  group('AlbumTile', () {
    testWidgets('shows the album and its length', (tester) async {
      await pump(tester, AlbumTile(album: album), size: const Size(400, 100));

      expect(find.text('Some Album'), findsOneWidget);
      expect(find.text('Some Artist'), findsOneWidget);
      expect(find.text('9 songs • 1h 2m'), findsOneWidget);
    });

    testWidgets('plays the album from the menu', (tester) async {
      await pump(tester, AlbumTile(album: album), size: const Size(400, 100));

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play Album'));
      await tester.pump();

      expect(player.played, [album]);
    });

    testWidgets('shows a spinner while starting and ignores another tap',
        (tester) async {
      await pump(tester, AlbumTile(album: album), size: const Size(400, 100));

      await tester.tap(find.text('Some Album'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.tap(find.text('Some Album'));
      await tester.pump();
      expect(player.played, [album]);

      player.result.complete();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('AlbumGridTile', () {
    testWidgets('shows the artist, or the number of songs', (tester) async {
      await pump(tester, AlbumGridTile(album: album));
      expect(find.text('Some Artist'), findsOneWidget);
      expect(find.text('9 songs'), findsNothing);

      await pump(tester, AlbumGridTile(album: album, showArtist: false));
      expect(find.text('Some Artist'), findsNothing);
      expect(find.text('9 songs'), findsOneWidget);
    });

    testWidgets('plays the album on tap', (tester) async {
      await pump(tester, AlbumGridTile(album: album));

      await tester.tap(find.text('Some Album'));
      await tester.pump();
      expect(player.played, [album]);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      player.result.complete();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('shows why playing failed', (tester) async {
      await pump(tester, AlbumGridTile(album: album));

      await tester.tap(find.text('Some Album'));
      await tester.pump();
      player.result
          .completeError(const UserFacingException('Album has no songs'));
      await tester.pump();

      expect(find.text('Failed to play album: Album has no songs'),
          findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('does nothing without a player', (tester) async {
      await tester.pumpWidget(ChangeNotifierProvider<AppState>(
        create: (_) => _FakeAppState(null),
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
                width: 200, height: 260, child: AlbumGridTile(album: album)),
          ),
        ),
      ));

      await tester.tap(find.text('Some Album'));
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
