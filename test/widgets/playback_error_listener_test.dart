import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/widgets/playback_error_listener.dart';

class _FakePlayer extends Mock implements AudioPlayerService {
  final errors = StreamController<String>.broadcast();

  @override
  Stream<String> get playbackErrors => errors.stream;

  @override
  void dispose() => unawaited(errors.close());
}

void main() {
  /// A player that's released at the end of the test, like the app's
  _FakePlayer newPlayer() {
    final player = _FakePlayer();
    addTearDown(player.dispose);
    return player;
  }

  Future<void> pump(WidgetTester tester, AudioPlayerService? player) =>
      tester.pumpWidget(
        MaterialApp(
          home: PlaybackErrorListener(
            player: player,
            child: const Scaffold(body: Text('home')),
          ),
        ),
      );

  testWidgets('shows a playback error as a snack bar', (tester) async {
    final player = newPlayer();
    await pump(tester, player);

    player.errors.add('Could not play "Song": Cannot reach server.');
    await tester.pumpAndSettle();

    expect(
      find.text('Could not play "Song": Cannot reach server.'),
      findsOneWidget,
    );
  });

  testWidgets('a new error replaces the one before', (tester) async {
    final player = newPlayer();
    await pump(tester, player);

    player.errors.add('first');
    await tester.pumpAndSettle();
    player.errors.add('second');
    await tester.pumpAndSettle();

    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);
  });

  testWidgets('follows the player of a new login', (tester) async {
    final old = newPlayer();
    final current = newPlayer();
    await pump(tester, old);
    await pump(tester, current);

    old.errors.add('old');
    current.errors.add('current');
    await tester.pumpAndSettle();

    expect(find.text('old'), findsNothing);
    expect(find.text('current'), findsOneWidget);
    expect(old.errors.hasListener, isFalse);
  });
}
