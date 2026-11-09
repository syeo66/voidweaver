import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';
import 'package:voidweaver/screens/search_screen.dart';
import 'package:voidweaver/services/app_state.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/network_errors.dart';
import 'package:voidweaver/services/subsonic_api.dart';

import '../test_helpers/mock_api.dart';
import '../test_helpers/mocks.mocks.dart';

/// An [AppState] that hands out the given API and player without logging in.
class _FakeAppState extends AppState {
  final SubsonicApi? _fakeApi;
  final AudioPlayerService? _player;

  _FakeAppState(this._fakeApi, [this._player]);

  @override
  SubsonicApi? get api => _fakeApi;

  @override
  AudioPlayerService? get audioPlayerService => _player;
}

/// Records the songs and albums played; each play finishes when [result] does.
class _FakePlayer extends Fake implements AudioPlayerService {
  final songs = <Song>[];
  final albums = <Album>[];

  // Created on first use, inside the test: a future belongs to the zone it
  // was created in, and one from setUp() would complete outside the test's
  // fake async zone, after the test
  late final result = Completer<void>();

  @override
  Future<void> playSong(Song song) {
    songs.add(song);
    return result.future;
  }

  @override
  Future<void> playAlbum(Album album) {
    albums.add(album);
    return result.future;
  }
}

void main() {
  late MockSubsonicApi mockApi;
  late _FakePlayer player;

  SearchResult resultWithArtists(int count) => SearchResult(
    artists: [
      for (var i = 0; i < count; i++) Artist(id: 'a$i', name: 'Artist $i'),
    ],
    albums: [],
    songs: [],
  );

  Widget screen() => ChangeNotifierProvider<AppState>(
    create: (_) => _FakeAppState(mockApi),
    child: const MaterialApp(home: SearchScreen()),
  );

  setUp(() {
    mockApi = newMockApi();
    player = _FakePlayer();
  });

  testWidgets('searches once typing pauses', (tester) async {
    when(mockApi.search(any)).thenAnswer((_) async => resultWithArtists(1));
    await tester.pumpWidget(screen());

    await tester.enterText(find.byType(TextField), 'a');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), 'ab');
    await tester.pump(const Duration(milliseconds: 300));
    verifyNever(mockApi.search(any));

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    verify(mockApi.search('ab')).called(1);
    verifyNever(mockApi.search('a'));
    expect(find.text('Artists (1)'), findsOneWidget);
  });

  testWidgets('drops the response to an older query', (tester) async {
    final older = Completer<SearchResult>();
    final newer = Completer<SearchResult>();
    when(mockApi.search('ab')).thenAnswer((_) => older.future);
    when(mockApi.search('abc')).thenAnswer((_) => newer.future);
    await tester.pumpWidget(screen());

    await tester.enterText(find.byType(TextField), 'ab');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump(const Duration(milliseconds: 500));
    verify(mockApi.search('ab')).called(1);
    verify(mockApi.search('abc')).called(1);

    newer.complete(resultWithArtists(1));
    await tester.pump();
    older.complete(resultWithArtists(2));
    await tester.pump();

    expect(find.text('Artists (1)'), findsOneWidget);
    expect(find.text('Artists (2)'), findsNothing);
  });

  testWidgets('drops a response that arrives after clearing the query', (
    tester,
  ) async {
    final pending = Completer<SearchResult>();
    when(mockApi.search(any)).thenAnswer((_) => pending.future);
    await tester.pumpWidget(screen());

    await tester.enterText(find.byType(TextField), 'ab');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(find.byType(TextField), '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    pending.complete(resultWithArtists(1));
    await tester.pump();

    expect(find.textContaining('Artists ('), findsNothing);
    expect(
      find.text('Enter a search term to find artists, albums, and songs'),
      findsOneWidget,
    );
  });

  testWidgets('does not search after the screen is closed', (tester) async {
    when(mockApi.search(any)).thenAnswer((_) async => resultWithArtists(1));
    await tester.pumpWidget(screen());

    await tester.enterText(find.byType(TextField), 'ab');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));

    verifyNever(mockApi.search(any));
    expect(tester.takeException(), isNull);
  });

  group('playing a result', () {
    final album = Album(id: 'al-1', name: 'Some Album', artist: 'Some Artist');
    final song = Song(
      id: 's-1',
      title: 'Some Song',
      artist: 'Some Artist',
      album: 'Some Album',
      duration: 185,
    );

    /// The search screen on top of a home page, with [album] and [song] found
    Future<void> openSearch(WidgetTester tester) async {
      when(mockApi.search(any)).thenAnswer(
        (_) async => SearchResult(artists: [], albums: [album], songs: [song]),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>(
          create: (_) => _FakeAppState(mockApi, player),
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Column(
                  children: [
                    const Text('Home'),
                    TextButton(
                      onPressed: () => unawaited(
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const SearchScreen(),
                          ),
                        ),
                      ),
                      child: const Text('Open search'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'some');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
    }

    Future<void> showTab(WidgetTester tester, String label) async {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    bool onHome(WidgetTester tester) =>
        find.byType(SearchScreen).evaluate().isEmpty &&
        find.text('Home').evaluate().isNotEmpty;

    testWidgets('shows a spinner on the song, and ignores more taps', (
      tester,
    ) async {
      await openSearch(tester);
      await showTab(tester, 'Songs (1)');
      expect(find.text('3:05'), findsOneWidget);

      await tester.tap(find.text('Some Song'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('3:05'), findsNothing);

      await tester.tap(find.text('Some Song'));
      await tester.pump();
      // Another result meanwhile is ignored as well
      await showTab(tester, 'Albums (1)');
      await tester.tap(find.text('Some Album'));
      await tester.pump();
      expect(player.songs, [song]);
      expect(player.albums, isEmpty);

      player.result.complete();
      await tester.pumpAndSettle();
      expect(onHome(tester), isTrue);
    });

    testWidgets('shows a spinner on the album, and ignores more taps', (
      tester,
    ) async {
      await openSearch(tester);
      await showTab(tester, 'Albums (1)');

      await tester.tap(find.text('Some Album'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.tap(find.text('Some Album'));
      await tester.pump();
      expect(player.albums, [album]);

      player.result.complete();
      await tester.pumpAndSettle();
      expect(onHome(tester), isTrue);
    });

    testWidgets('a failed song shows why, in the error colour', (tester) async {
      await openSearch(tester);
      await showTab(tester, 'Songs (1)');

      await tester.tap(find.text('Some Song'));
      await tester.pump();
      player.result.completeError(const UserFacingException('No such song'));
      await tester.pump();

      expect(find.text('Failed to play song: No such song'), findsOneWidget);
      final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(
        snackBar.backgroundColor,
        Theme.of(tester.element(find.byType(SnackBar))).colorScheme.error,
      );
      // Stays on the results, with the spinner gone and the duration back
      expect(find.byType(SearchScreen), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('3:05'), findsOneWidget);

      // Another try is possible
      await tester.tap(find.text('Some Song'));
      await tester.pump();
      expect(player.songs, [song, song]);
    });
  });

  testWidgets('stops loading when logged out', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>(
        create: (_) => _FakeAppState(null),
        child: const MaterialApp(home: SearchScreen()),
      ),
    );

    await tester.enterText(find.byType(TextField), 'ab');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      find.text('Enter a search term to find artists, albums, and songs'),
      findsOneWidget,
    );
  });
}
