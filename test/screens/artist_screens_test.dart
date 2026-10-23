import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';
import 'package:voidweaver/screens/artist_detail_screen.dart';
import 'package:voidweaver/screens/artist_screen.dart';
import 'package:voidweaver/services/app_state.dart';
import 'package:voidweaver/services/subsonic_api.dart';

import 'artist_screens_test.mocks.dart';

/// An [AppState] that hands out the given API without logging in.
class _FakeAppState extends AppState {
  final SubsonicApi? _fakeApi;

  _FakeAppState(this._fakeApi);

  @override
  SubsonicApi? get api => _fakeApi;
}

@GenerateMocks([SubsonicApi])
void main() {
  late MockSubsonicApi mockApi;

  final artistA = Artist(id: 'a', name: 'Artist A');
  final artistB = Artist(id: 'b', name: 'Artist B');

  List<Album> albums(String prefix, int count) => [
        for (var i = 0; i < count; i++)
          Album(id: '$prefix$i', name: '$prefix album $i', artist: prefix)
      ];

  Widget app(Widget home, {SubsonicApi? api}) =>
      ChangeNotifierProvider<AppState>(
        create: (_) => _FakeAppState(api),
        child: MaterialApp(home: home),
      );

  setUp(() {
    mockApi = MockSubsonicApi();
  });

  group('ArtistScreen', () {
    testWidgets('lists the artists and shows the albums of a tapped one',
        (tester) async {
      when(mockApi.getArtists()).thenAnswer((_) async => [artistA, artistB]);
      when(mockApi.getArtistAlbums('a'))
          .thenAnswer((_) async => albums('A', 2));
      await tester.pumpWidget(app(const ArtistScreen(), api: mockApi));
      await tester.pump();

      expect(find.text('Artist A'), findsOneWidget);
      expect(find.text('Artist B'), findsOneWidget);

      await tester.tap(find.text('Artist A'));
      await tester.pump();

      expect(find.text('A album 0'), findsOneWidget);
      expect(find.text('A album 1'), findsOneWidget);
    });

    testWidgets('ignores artists arriving after the screen is gone',
        (tester) async {
      final artists = Completer<List<Artist>>();
      when(mockApi.getArtists()).thenAnswer((_) => artists.future);
      await tester.pumpWidget(app(const ArtistScreen(), api: mockApi));

      await tester.pumpWidget(const SizedBox());
      artists.complete([artistA]);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('ignores an error arriving after the screen is gone',
        (tester) async {
      final artists = Completer<List<Artist>>();
      when(mockApi.getArtists()).thenAnswer((_) => artists.future);
      await tester.pumpWidget(app(const ArtistScreen(), api: mockApi));

      await tester.pumpWidget(const SizedBox());
      artists.completeError(Exception('offline'));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('drops the albums of an artist the user went back from',
        (tester) async {
      final albumsA = Completer<List<Album>>();
      when(mockApi.getArtists()).thenAnswer((_) async => [artistA, artistB]);
      when(mockApi.getArtistAlbums('a')).thenAnswer((_) => albumsA.future);
      when(mockApi.getArtistAlbums('b'))
          .thenAnswer((_) async => albums('B', 1));
      await tester.pumpWidget(app(const ArtistScreen(), api: mockApi));
      await tester.pump();

      await tester.tap(find.text('Artist A'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      await tester.tap(find.text('Artist B'));
      await tester.pump();
      expect(find.text('B album 0'), findsOneWidget);

      albumsA.complete(albums('A', 1));
      await tester.pump();

      expect(find.text('B album 0'), findsOneWidget);
      expect(find.text('A album 0'), findsNothing);
    });

    testWidgets('drops an album error after going back to the artists',
        (tester) async {
      final albumsA = Completer<List<Album>>();
      when(mockApi.getArtists()).thenAnswer((_) async => [artistA]);
      when(mockApi.getArtistAlbums('a')).thenAnswer((_) => albumsA.future);
      await tester.pumpWidget(app(const ArtistScreen(), api: mockApi));
      await tester.pump();

      await tester.tap(find.text('Artist A'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();

      albumsA.completeError(Exception('offline'));
      await tester.pump();

      expect(find.text('Retry'), findsNothing);
      expect(find.text('Artist A'), findsOneWidget);
    });

    testWidgets('shows no spinner without an API', (tester) async {
      await tester.pumpWidget(app(const ArtistScreen()));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('No artists found'), findsOneWidget);
    });
  });

  group('ArtistDetailScreen', () {
    testWidgets('shows the artist\'s albums', (tester) async {
      when(mockApi.getArtistAlbums('a'))
          .thenAnswer((_) async => albums('A', 2));
      await tester
          .pumpWidget(app(ArtistDetailScreen(artist: artistA), api: mockApi));
      await tester.pump();

      expect(find.text('A album 0'), findsOneWidget);
      expect(find.text('A album 1'), findsOneWidget);
    });

    testWidgets('ignores albums arriving after the screen is gone',
        (tester) async {
      final albumsA = Completer<List<Album>>();
      when(mockApi.getArtistAlbums('a')).thenAnswer((_) => albumsA.future);
      await tester
          .pumpWidget(app(ArtistDetailScreen(artist: artistA), api: mockApi));

      await tester.pumpWidget(const SizedBox());
      albumsA.complete(albums('A', 1));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('ignores an error arriving after the screen is gone',
        (tester) async {
      final albumsA = Completer<List<Album>>();
      when(mockApi.getArtistAlbums('a')).thenAnswer((_) => albumsA.future);
      await tester
          .pumpWidget(app(ArtistDetailScreen(artist: artistA), api: mockApi));

      await tester.pumpWidget(const SizedBox());
      albumsA.completeError(Exception('offline'));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('shows no spinner without an API', (tester) async {
      await tester.pumpWidget(app(ArtistDetailScreen(artist: artistA)));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('No albums found for this artist'), findsOneWidget);
    });
  });
}
