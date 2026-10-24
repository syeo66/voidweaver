import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';
import 'package:voidweaver/screens/search_screen.dart';
import 'package:voidweaver/services/app_state.dart';
import 'package:voidweaver/services/subsonic_api.dart';

import '../test_helpers/mocks.mocks.dart';

/// An [AppState] that hands out the given API without logging in.
class _FakeAppState extends AppState {
  final SubsonicApi _fakeApi;

  _FakeAppState(this._fakeApi);

  @override
  SubsonicApi? get api => _fakeApi;
}

void main() {
  late MockSubsonicApi mockApi;

  SearchResult resultWithArtists(int count) => SearchResult(
        artists: [
          for (var i = 0; i < count; i++) Artist(id: 'a$i', name: 'Artist $i')
        ],
        albums: [],
        songs: [],
      );

  Widget screen() => ChangeNotifierProvider<AppState>(
        create: (_) => _FakeAppState(mockApi),
        child: const MaterialApp(home: SearchScreen()),
      );

  setUp(() {
    mockApi = MockSubsonicApi();
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

  testWidgets('drops a response that arrives after clearing the query',
      (tester) async {
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
    expect(find.text('Enter a search term to find artists, albums, and songs'),
        findsOneWidget);
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
}
