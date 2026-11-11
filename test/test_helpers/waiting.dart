import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/services/playback_persistence.dart';

/// Lets the code under test run until [condition] holds: pumps the event
/// queue (microtasks and zero-length timers), then waits a little real time
/// for longer timers and I/O, again and again. Fails after [timeout].
/// [condition] can be async, e.g. to read back what was saved.
///
/// Use it instead of a fixed `Future.delayed`, which is too short on a slow
/// machine and wastes time on a fast one. For a check that something did
/// *not* happen, wait for what shows the work is done (a queue drained, the
/// player's operations finished), then check.
Future<void> pumpUntil(
  FutureOr<bool> Function() condition, {
  String? reason,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    await pumpEventQueue();
    if (await condition()) return;
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out after $timeout waiting for ${reason ?? 'a condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A test whose [body] runs in fake time (see [fakeAsync]): timers fire only
/// when the body moves the clock with [FakeAsync.elapse], so the test needs
/// no real time and every run is the same. Await futures in the body with
/// [awaitFake].
///
/// Not for the player service: see test/README.md.
void testInFakeTime(String description, void Function(FakeAsync async) body) {
  test(description, () => fakeAsync(body));
}

/// The result of [future] in fake time: runs its microtasks, and moves the
/// clock in 1 ms steps while it waits for a timer. Fails if it takes more
/// than [limit] of fake time, so it can't run into timers far ahead (e.g. a
/// retry) unnoticed.
T awaitFake<T>(
  FakeAsync async,
  Future<T> future, {
  Duration limit = const Duration(seconds: 10),
}) {
  late T result;
  Object? error;
  StackTrace? stack;
  var done = false;
  unawaited(
    future.then(
      (value) {
        result = value;
        done = true;
      },
      onError: (Object e, StackTrace s) {
        error = e;
        stack = s;
        done = true;
      },
    ),
  );
  final until = async.elapsed + limit;
  async.flushMicrotasks();
  while (!done) {
    if (async.elapsed >= until) fail('Not done after $limit of fake time');
    async.elapse(const Duration(milliseconds: 1));
  }
  final e = error;
  if (e != null) Error.throwWithStackTrace(e, stack!);
  return result;
}

/// [pumpUntil] for widget tests whose code does real I/O: runs it outside
/// the test's fake clock ([WidgetTester.runAsync]) and pumps a frame between
/// checks, so [condition] can look at the widgets.
Future<void> pumpFramesUntil(
  WidgetTester tester,
  bool Function() condition, {
  String? reason,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    await tester.pump();
    if (condition()) return;
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out after $timeout waiting for ${reason ?? 'a condition'}');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}

/// Waits until the saves [persistence] has started are written. Lets a save
/// get past its SharedPreferences write (in memory in tests, so microtasks
/// only) and queue its file write, then reads: a read comes after the file
/// writes queued before it (see `PlaybackPersistenceService._readPosition`).
///
/// Only waits when a queue is saved: without one, the read returns before
/// it touches the file. A save writes the queue first whenever it isn't
/// known to be saved (the first save, the first after a clear), so this
/// holds unless a test removes the queue behind the persistence's back. Not
/// for a timed save still waiting for its timer. In a tearDown, use
/// [allSavesWritten].
Future<void> savesWritten(PlaybackPersistenceService persistence) async {
  await pumpEventQueue();
  await persistence.loadPlaybackState();
}

/// For a tearDown: waits for every write [persistence] has queued, with or
/// without a saved queue, by clearing what it saved (the clear comes after
/// the queued writes). Call it after `dispose()`, which writes a pending
/// position save.
Future<void> allSavesWritten(PlaybackPersistenceService persistence) async {
  await pumpEventQueue();
  await persistence.clearPlaybackState();
}
