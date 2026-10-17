import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:voidweaver/services/app_state.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:voidweaver/widgets/album_list.dart';

/// An [AppState] with fixed albums, error and loading flag
class _StubAppState extends AppState {
  _StubAppState({this.stubAlbums = const [], this.stubError});

  final List<Album> stubAlbums;
  final String? stubError;
  bool stubLoading = false;

  @override
  List<Album> get albums => stubAlbums;

  @override
  String? get error => stubError;

  @override
  bool get isLoading => stubLoading;
}

Future<void> _pumpAlbumList(WidgetTester tester, AppState appState) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChangeNotifierProvider<AppState>.value(
          value: appState,
          child: const AlbumList(),
        ),
      ),
    ),
  );
}

void main() {
  final album = Album(
    id: '1',
    name: 'Loaded Album',
    artist: 'Artist',
    songs: const [],
  );

  group('AlbumList', () {
    testWidgets('shows the error when no albums are loaded', (tester) async {
      await _pumpAlbumList(tester, _StubAppState(stubError: 'offline'));

      expect(find.text('Error: offline'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('keeps the loaded albums when a refresh fails', (tester) async {
      await _pumpAlbumList(
          tester, _StubAppState(stubAlbums: [album], stubError: 'offline'));

      expect(find.text('Loaded Album'), findsOneWidget);
      expect(find.text('Error: offline'), findsNothing);
    });

    testWidgets('keeps the loaded albums while refreshing', (tester) async {
      final appState = _StubAppState(stubAlbums: [album])..stubLoading = true;
      await _pumpAlbumList(tester, appState);

      expect(find.text('Loaded Album'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('shows a spinner while the first load runs', (tester) async {
      final appState = _StubAppState()..stubLoading = true;
      await _pumpAlbumList(tester, appState);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}
