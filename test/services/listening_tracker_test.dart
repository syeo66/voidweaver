import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:voidweaver/services/listening_tracker.dart';

import '../test_helpers/mocks.mocks.dart';

void main() {
  const song = Duration(minutes: 4);
  late DateTime now;
  late ListeningTracker tracker;

  /// [seconds] of playback: one position update per second
  void play(int seconds, {bool playing = true}) {
    var position = tracker.listened;
    for (var i = 0; i < seconds; i++) {
      now = now.add(const Duration(seconds: 1));
      position += const Duration(seconds: 1);
      tracker.onPosition(position, playing: playing);
    }
  }

  setUp(() {
    now = DateTime(2026, 11, 3, 22);
    final settings = MockSettingsService();
    when(settings.scrobbleMinPlayTimeMinutes).thenReturn(4.0);
    when(settings.scrobbleThresholdPercent).thenReturn(50.0);
    tracker = ListeningTracker(settings, clock: () => now);
  });

  test('scrobbles once at the threshold, with the start time', () {
    final start = now;
    tracker.startPlay(Duration.zero, song, playing: true);
    play(119);
    expect(tracker.takeScrobble(song), isNull);
    play(1);
    expect(tracker.takeScrobble(song), start);
    expect(tracker.takeScrobble(song), isNull);
  });

  test('a seek is not listening', () {
    tracker.startPlay(Duration.zero, song, playing: true);
    play(10);
    now = now.add(const Duration(seconds: 1));
    tracker.onPosition(const Duration(minutes: 3), playing: true);
    expect(tracker.listened, const Duration(seconds: 10));
    expect(tracker.takeScrobble(song), isNull);
  });

  test('counts nothing while not playing', () {
    tracker.startPlay(Duration.zero, song, playing: true);
    play(30, playing: false);
    expect(tracker.listened, Duration.zero);
  });

  test('a track played to its end counts in full', () {
    tracker.startPlay(Duration.zero, song, playing: true);
    play(100);
    tracker.listenedToEnd(song);
    expect(tracker.listened, song);
  });

  test('a restored song scrobbles only after it has been played', () {
    tracker.startPlay(const Duration(seconds: 30), song, playing: false);
    expect(tracker.hasStarted, isFalse);
    expect(tracker.listened, const Duration(seconds: 30));
    play(100);
    expect(tracker.takeScrobble(song), isNull);

    tracker.markStarted();
    expect(tracker.takeScrobble(song), isNotNull);
  });

  test('a song restored past the threshold was scrobbled before', () {
    tracker.startPlay(const Duration(minutes: 3), song, playing: true);
    play(30);
    expect(tracker.takeScrobble(song), isNull);
  });
}
