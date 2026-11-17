import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/scrobble_queue.dart';
import 'package:voidweaver/services/subsonic_api.dart';

import '../test_helpers/mock_api.dart';
import '../test_helpers/mocks.mocks.dart';
import '../test_helpers/waiting.dart';

// In fake time: the queue's timers (100 ms between requests, the retries)
// fire only when a test moves the clock, so no test waits real time and the
// retry delays can be checked exactly.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScrobbleQueue Tests', () {
    late MockSubsonicApi mockApi;
    late ScrobbleQueue scrobbleQueue;

    /// Lets the queue send what it can. Well short of the first retry (30 s).
    void settle(FakeAsync async) => async.elapse(const Duration(seconds: 1));

    /// The songs a start after the process was killed would send, in order:
    /// a new queue loads what's stored and sends it to a server that accepts
    /// everything. Empties the storage.
    List<String> sentByNextStart(FakeAsync async) {
      final api = newMockApi();
      final songs = <String>[];
      when(api.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((call) async {
            songs.add(call.positionalArguments.first as String);
          });
      when(api.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
          .thenAnswer((call) async {
            songs.add(call.positionalArguments.first as String);
          });
      final next = ScrobbleQueue(api);
      awaitFake(async, next.initialize());
      settle(async);
      next.dispose();
      return songs;
    }

    setUp(() async {
      mockApi = newMockApi();
      SharedPreferences.setMockInitialValues({});
      scrobbleQueue = ScrobbleQueue(mockApi);
    });

    tearDown(() {
      scrobbleQueue.dispose();
    });

    testInFakeTime('should initialize with empty queue', (async) {
      awaitFake(async, scrobbleQueue.initialize());
      expect(scrobbleQueue.queueSize, 0);
    });

    testInFakeTime('should queue now playing notification', (async) {
      when(mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
          .thenAnswer((_) => Future.delayed(const Duration(milliseconds: 100)));
      awaitFake(async, scrobbleQueue.initialize());

      awaitFake(async, scrobbleQueue.queueNowPlaying('song1'));

      expect(scrobbleQueue.queueSize, 1);
    });

    testInFakeTime('should queue scrobble submission', (async) {
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) => Future.delayed(const Duration(milliseconds: 100)));
      awaitFake(async, scrobbleQueue.initialize());

      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
      );

      expect(scrobbleQueue.queueSize, 1);
    });

    testInFakeTime('counts only submissions as pending plays', (async) {
      when(mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
          .thenAnswer((_) => Future.delayed(const Duration(milliseconds: 100)));
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) => Future.delayed(const Duration(milliseconds: 100)));
      awaitFake(async, scrobbleQueue.initialize());

      awaitFake(async, scrobbleQueue.queueNowPlaying('song1'));
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song2', playedAt: DateTime.now()),
      );

      expect(scrobbleQueue.queueSize, 3);
      expect(scrobbleQueue.pendingSubmissions, 2);
    });

    testInFakeTime('should process now playing request successfully', (async) {
      when(mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
          .thenAnswer((_) async {});

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(async, scrobbleQueue.queueNowPlaying('song1'));
      settle(async);

      verify(
        mockApi.scrobbleNowPlaying('song1', startedAt: anyNamed('startedAt')),
      ).called(1);
      expect(scrobbleQueue.queueSize, 0);
    });

    testInFakeTime('should process submission request successfully', (async) {
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {});

      awaitFake(async, scrobbleQueue.initialize());
      final timestamp = DateTime.now();
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song1', playedAt: timestamp),
      );
      settle(async);

      verify(mockApi.scrobbleSubmission('song1', playedAt: timestamp))
          .called(1);
      expect(scrobbleQueue.queueSize, 0);
    });

    testInFakeTime('should retry failed submissions', (async) {
      var callCount = 0;
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {
            callCount++;
            if (callCount <= 2) {
              throw Exception('Network error');
            }
          });

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      settle(async);
      expect(scrobbleQueue.queueSize, 1);

      awaitFake(async, scrobbleQueue.processQueue());
      expect(scrobbleQueue.queueSize, 1);

      awaitFake(async, scrobbleQueue.processQueue());
      verify(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      ).called(3);
      expect(scrobbleQueue.queueSize, 0);
    });

    testInFakeTime('should not retry right away after a failure', (async) {
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenThrow(Exception('Network error'));

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      async.elapse(const Duration(seconds: 29));

      // Retried by the 30 s timer, not in a loop
      verify(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      ).called(1);
      expect(scrobbleQueue.queueSize, 1);

      async.elapse(const Duration(seconds: 1));
      verify(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      ).called(1);
    });

    testInFakeTime(
      'should keep a submission through repeated network failures',
      (async) {
        when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
            .thenThrow(Exception('Network error'));

        awaitFake(async, scrobbleQueue.initialize());
        awaitFake(
          async,
          scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
        );
        for (var i = 0; i < 10; i++) {
          awaitFake(async, scrobbleQueue.processQueue());
        }

        // Only dropped once it's older than 7 days
        expect(scrobbleQueue.queueSize, 1);
      },
    );

    testInFakeTime('should keep later requests behind a failed submission', (
      async,
    ) {
      final sent = <String>[];
      var online = false;
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((invocation) async {
            if (!online) throw Exception('Network error');
            sent.add(invocation.positionalArguments[0] as String);
          });

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song2', playedAt: DateTime.now()),
      );
      settle(async);

      // song2 wasn't tried while song1 was failing
      verifyNever(
        mockApi.scrobbleSubmission('song2', playedAt: anyNamed('playedAt')),
      );
      expect(scrobbleQueue.queueSize, 2);

      online = true;
      awaitFake(async, scrobbleQueue.processQueue());
      expect(sent, ['song1', 'song2']);
      expect(scrobbleQueue.queueSize, 0);
    });

    testInFakeTime(
      'keeps a now playing that fails and sends it later with its start time',
      (async) {
        final started = DateTime(2026, 11, 14, 23, 5);
        final queue = ScrobbleQueue(mockApi, clock: () => started);
        addTearDown(queue.dispose);
        var online = false;
        final sent = <(String, DateTime?)>[];
        when(mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
            .thenAnswer((invocation) async {
              if (!online) throw const SocketException('offline');
              sent.add((
                invocation.positionalArguments[0] as String,
                invocation.namedArguments[#startedAt] as DateTime?,
              ));
            });

        awaitFake(async, queue.initialize());
        awaitFake(async, queue.queueNowPlaying('song1'));
        settle(async);
        expect(queue.queueSize, 1);
        expect(queue.retryScheduled, isTrue);

        online = true;
        queue.networkAvailable();
        settle(async);
        // When it was queued, not when it was sent
        expect(sent, [('song1', started)]);
        expect(queue.queueSize, 0);
      },
    );

    testInFakeTime('should drop a now playing the server rejects', (async) {
      when(mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
          .thenThrow(const SubsonicException(70, 'Song not found'));

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(async, scrobbleQueue.queueNowPlaying('song1'));
      settle(async);

      expect(scrobbleQueue.queueSize, 0);
      expect(scrobbleQueue.retryScheduled, isFalse);
    });

    testInFakeTime('should drop a submission the server rejects', (async) {
      when(mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')))
          .thenThrow(const SubsonicException(70, 'Song not found'));
      when(mockApi.scrobbleSubmission('song2', playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {});

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song2', playedAt: DateTime.now()),
      );
      settle(async);

      verify(
        mockApi.scrobbleSubmission('song2', playedAt: anyNamed('playedAt')),
      ).called(1);
      expect(scrobbleQueue.queueSize, 0);
    });

    testInFakeTime(
      'should keep a submission refused because of the credentials',
      (async) {
        when(
          mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')),
        ).thenThrow(const SubsonicException(40, 'Wrong username or password'));

        awaitFake(async, scrobbleQueue.initialize());
        awaitFake(
          async,
          scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
        );
        settle(async);

        expect(scrobbleQueue.queueSize, 1);
      },
    );

    testInFakeTime('should drop requests older than 7 days', (async) {
      SharedPreferences.setMockInitialValues({
        'scrobble_queue': jsonEncode([
          ScrobbleRequest(
            songId: 'old',
            type: ScrobbleType.submission,
            playedAt: DateTime.now().subtract(const Duration(days: 8)),
            queuedAt: DateTime.now().subtract(const Duration(days: 8)),
          ).toJson(),
        ]),
      });

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(async, scrobbleQueue.processQueue());

      verifyNever(
        mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')),
      );
      expect(scrobbleQueue.queueSize, 0);
    });

    testInFakeTime('drops only the entries it cannot read', (async) {
      final playedAt = DateTime(2026, 11, 1, 22);
      SharedPreferences.setMockInitialValues({
        'scrobble_queue': jsonEncode([
          {'songId': 'unknown-type', 'type': 'love', 'queuedAt': 0},
          'not an object',
          {'type': 'submission'},
          ScrobbleRequest(
            songId: 'song1',
            type: ScrobbleType.submission,
            playedAt: playedAt,
            queuedAt: DateTime.now(),
          ).toJson(),
        ]),
      });
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {});

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(async, scrobbleQueue.processQueue());

      verify(mockApi.scrobbleSubmission('song1', playedAt: playedAt)).called(1);
      expect(scrobbleQueue.queueSize, 0);
    });

    testInFakeTime('saves now playing requests too', (async) {
      final online = Completer<void>();
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) => online.future);
      when(mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
          .thenAnswer((_) async {});

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      // Behind the submission that's still being sent
      awaitFake(async, scrobbleQueue.queueNowPlaying('song2'));
      async.flushMicrotasks();
      expect(scrobbleQueue.queueSize, 2);

      final prefs = awaitFake(async, SharedPreferences.getInstance());
      final saved = jsonDecode(prefs.getString('scrobble_queue')!) as List;
      expect(saved, [
        allOf(
          containsPair('songId', 'song1'),
          containsPair('type', 'submission'),
        ),
        allOf(
          containsPair('songId', 'song2'),
          containsPair('type', 'nowPlaying'),
        ),
      ]);
      online.complete();
    });

    testInFakeTime('removes each sent submission from storage at once', (
      async,
    ) {
      // A backlog sent in one pass: song1 goes through, song2 is still on
      // its way when the process is killed.
      //
      // Both queued before song1's answer, so queueing doesn't save the
      // queue after song1 is sent
      final song1Sent = Completer<void>();
      final song2Sent = Completer<void>();
      when(mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')))
          .thenAnswer((_) => song1Sent.future);
      when(mockApi.scrobbleSubmission('song2', playedAt: anyNamed('playedAt')))
          .thenAnswer((_) => song2Sent.future);

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song2', playedAt: DateTime.now()),
      );
      song1Sent.complete();
      // Past the 100 ms between requests: song2 is being sent
      settle(async);
      verify(
        mockApi.scrobbleSubmission('song2', playedAt: anyNamed('playedAt')),
      ).called(1);

      // What the next start would send: only the play the server hasn't
      // confirmed, not song1 a second time
      expect(sentByNextStart(async), ['song2']);
      song2Sent.complete();
    });

    testInFakeTime('removes each sent now playing from storage at once', (
      async,
    ) {
      // A backlog of "now playing" requests: sent again after a kill, one
      // the server already has would make the song played since look
      // skipped
      //
      // Both queued before song1's answer, so queueing doesn't save the
      // queue after song1 is sent
      final song1Sent = Completer<void>();
      final song2Sent = Completer<void>();
      when(
        mockApi.scrobbleNowPlaying('song1', startedAt: anyNamed('startedAt')),
      ).thenAnswer((_) => song1Sent.future);
      when(
        mockApi.scrobbleNowPlaying('song2', startedAt: anyNamed('startedAt')),
      ).thenAnswer((_) => song2Sent.future);

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(async, scrobbleQueue.queueNowPlaying('song1'));
      awaitFake(async, scrobbleQueue.queueNowPlaying('song2'));
      song1Sent.complete();
      // Past the 100 ms between requests: song2 is being sent
      settle(async);
      verify(
        mockApi.scrobbleNowPlaying('song2', startedAt: anyNamed('startedAt')),
      ).called(1);

      expect(sentByNextStart(async), ['song2']);
      song2Sent.complete();
    });

    testInFakeTime('a backlog doesn\'t rewrite the stored list per request', (
      async,
    ) {
      // Android rewrites its whole preferences file on every write, the
      // settings and the saved queue included: a week offline would do that
      // thousands of times if each sent request saved the list again
      final blocked = Completer<void>();
      final sentIds = <String>[];
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((call) {
            final id = call.positionalArguments.first as String;
            if (id == 'song4') return blocked.future;
            sentIds.add(id);
            return Future.value();
          });
      final playedAt = DateTime.now();
      SharedPreferences.setMockInitialValues({
        'scrobble_queue': jsonEncode([
          for (final id in ['song1', 'song2', 'song3', 'song4', 'song5'])
            ScrobbleRequest(
              songId: id,
              type: ScrobbleType.submission,
              playedAt: playedAt,
              queuedAt: playedAt,
            ).toJson(),
        ]),
      });
      final prefs = awaitFake(async, SharedPreferences.getInstance());
      final before = prefs.getString('scrobble_queue');

      awaitFake(async, scrobbleQueue.initialize());
      settle(async);

      // Three sent, the fourth is on its way
      expect(sentIds, ['song1', 'song2', 'song3']);
      expect(prefs.getString('scrobble_queue'), before);
      // A restart sends what's left, not what the server has
      expect(sentByNextStart(async), ['song4', 'song5']);
      blocked.complete();
    });

    testInFakeTime('a restart skips what the stored progress says was sent', (
      async,
    ) {
      final playedAt = DateTime.now();
      final requests = [
        for (final id in ['song1', 'song2', 'song3'])
          ScrobbleRequest(
            songId: id,
            type: ScrobbleType.submission,
            playedAt: playedAt,
            queuedAt: playedAt,
          ).toJson(),
      ];
      SharedPreferences.setMockInitialValues({
        'scrobble_queue': jsonEncode(requests),
        'scrobble_queue_sent': jsonEncode({
          'first':
              'submission/song1/${playedAt.millisecondsSinceEpoch}/'
              '${playedAt.millisecondsSinceEpoch}',
          'handled': 2,
        }),
      });

      expect(sentByNextStart(async), ['song3']);
    });

    testInFakeTime('a restart ignores progress stored for another list', (
      async,
    ) {
      // The list was written again (a request queued) after the progress,
      // and the app was killed before the progress was removed
      final playedAt = DateTime.now();
      SharedPreferences.setMockInitialValues({
        'scrobble_queue': jsonEncode([
          for (final id in ['song2', 'song3'])
            ScrobbleRequest(
              songId: id,
              type: ScrobbleType.submission,
              playedAt: playedAt,
              queuedAt: playedAt,
            ).toJson(),
        ]),
        'scrobble_queue_sent': jsonEncode({
          'first':
              'submission/song1/${playedAt.millisecondsSinceEpoch}/'
              '${playedAt.millisecondsSinceEpoch}',
          'handled': 1,
        }),
      });

      expect(sentByNextStart(async), ['song2', 'song3']);
    });

    testInFakeTime('a restart with everything sent leaves nothing stored', (
      async,
    ) {
      final playedAt = DateTime.now();
      final request = ScrobbleRequest(
        songId: 'song1',
        type: ScrobbleType.submission,
        playedAt: playedAt,
        queuedAt: playedAt,
      );
      SharedPreferences.setMockInitialValues({
        'scrobble_queue': jsonEncode([request.toJson()]),
        'scrobble_queue_sent': jsonEncode({
          'first':
              'submission/song1/${playedAt.millisecondsSinceEpoch}/'
              '${playedAt.millisecondsSinceEpoch}',
          'handled': 1,
        }),
      });

      awaitFake(async, scrobbleQueue.initialize());
      settle(async);

      verifyNever(
        mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')),
      );
      final prefs = awaitFake(async, SharedPreferences.getInstance());
      expect(prefs.getString('scrobble_queue'), isNull);
      expect(prefs.getString('scrobble_queue_sent'), isNull);
    });

    testInFakeTime('a restart after an unreadable entry skips what was sent', (
      async,
    ) {
      // The unreadable entry in the middle isn't in the queue, so the
      // progress must count from a list without it
      final playedAt = DateTime.now();
      final blocked = Completer<void>();
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((call) {
            return call.positionalArguments.first == 'songD'
                ? blocked.future
                : Future.value();
          });
      Map<String, dynamic> submission(String id) => ScrobbleRequest(
        songId: id,
        type: ScrobbleType.submission,
        playedAt: playedAt,
        queuedAt: playedAt,
      ).toJson();
      SharedPreferences.setMockInitialValues({
        'scrobble_queue': jsonEncode([
          submission('songA'),
          {'type': 'love'},
          submission('songC'),
          submission('songD'),
        ]),
      });

      awaitFake(async, scrobbleQueue.initialize());
      settle(async);

      verify(
        mockApi.scrobbleSubmission('songC', playedAt: anyNamed('playedAt')),
      ).called(1);
      // Killed with songD on its way: A and C aren't sent again
      expect(sentByNextStart(async), ['songD']);
      blocked.complete();
    });

    testInFakeTime('knows which server errors are generic', (async) {
      expect(const SubsonicException(0, 'x').isGenericError, isTrue);
      expect(const SubsonicException(null, 'x').isGenericError, isTrue);
      expect(const SubsonicException(70, 'x').isGenericError, isFalse);
      expect(const SubsonicException(40, 'x').isGenericError, isFalse);
    });

    testInFakeTime(
      'keeps a request after a generic server error without a code',
      (async) {
        when(
          mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
        ).thenThrow(const SubsonicException(null, 'something went wrong'));

        awaitFake(async, scrobbleQueue.initialize());
        awaitFake(
          async,
          scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
        );
        settle(async);

        expect(scrobbleQueue.queueSize, 1);
        expect(scrobbleQueue.retryScheduled, isTrue);
      },
    );

    testInFakeTime('counts the hour from the last time it failed that way', (
      async,
    ) {
      // A generic error, then a long time offline: the next generic error
      // starts a new hour rather than ending the first
      final start = DateTime(2026, 11, 17, 9);
      scrobbleQueue.dispose();
      scrobbleQueue = ScrobbleQueue(
        mockApi,
        clock: () => start.add(async.elapsed),
      );
      var answer = 'generic';
      when(mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {
            if (answer == 'offline') throw Exception('offline');
            throw const SubsonicException(0, 'database is locked');
          });

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(async, scrobbleQueue.queueSubmission('song1', playedAt: start));
      settle(async);
      answer = 'offline';
      async.elapse(const Duration(hours: 3));
      answer = 'generic';
      async.elapse(const Duration(minutes: 6));

      expect(scrobbleQueue.queueSize, 1);
    });

    testInFakeTime('keeps a request after a generic server error', (async) {
      // Code 0: no reason given, maybe the server's trouble of the moment
      var failing = true;
      when(mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {
            if (failing) throw const SubsonicException(0, 'database is locked');
          });

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      settle(async);

      expect(scrobbleQueue.queueSize, 1);
      expect(scrobbleQueue.retryScheduled, isTrue);

      failing = false;
      async.elapse(const Duration(seconds: 30));
      expect(scrobbleQueue.queueSize, 0);
    });

    testInFakeTime('drops a request that keeps failing with a generic error', (
      async,
    ) {
      // One that never works must not block the plays behind it until it's a
      // week old
      // The queue's clock follows the fake time (DateTime.now() doesn't)
      final start = DateTime(2026, 11, 17, 9);
      scrobbleQueue.dispose();
      scrobbleQueue = ScrobbleQueue(
        mockApi,
        clock: () => start.add(async.elapsed),
      );
      when(mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')))
          .thenThrow(const SubsonicException(0, 'cannot be scrobbled'));
      when(mockApi.scrobbleSubmission('song2', playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {});

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song2', playedAt: DateTime.now()),
      );
      settle(async);
      expect(scrobbleQueue.queueSize, 2);

      async.elapse(const Duration(minutes: 59));
      expect(scrobbleQueue.queueSize, 2);

      // The timer's tries are at most 5 minutes apart
      async.elapse(const Duration(minutes: 7));
      expect(scrobbleQueue.queueSize, 0);
      verify(
        mockApi.scrobbleSubmission('song2', playedAt: anyNamed('playedAt')),
      ).called(1);
    });

    testInFakeTime('loads saved now playing requests and sends them in order', (
      async,
    ) {
      // What a kill while offline leaves: a skipped song, then a play
      final skippedAt = DateTime(2026, 11, 14, 22);
      final playedAt = skippedAt.add(const Duration(seconds: 20));
      SharedPreferences.setMockInitialValues({
        'scrobble_queue': jsonEncode([
          ScrobbleRequest(
            songId: 'skipped',
            type: ScrobbleType.nowPlaying,
            queuedAt: skippedAt,
          ).toJson(),
          ScrobbleRequest(
            songId: 'song1',
            type: ScrobbleType.nowPlaying,
            queuedAt: playedAt,
          ).toJson(),
          ScrobbleRequest(
            songId: 'song1',
            type: ScrobbleType.submission,
            playedAt: playedAt,
            queuedAt: playedAt.add(const Duration(minutes: 2)),
          ).toJson(),
        ]),
      });
      final sent = <String>[];
      when(mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
          .thenAnswer((invocation) async {
            sent.add(
              'now playing ${invocation.positionalArguments[0]} '
              'at ${invocation.namedArguments[#startedAt]}',
            );
          });
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((invocation) async {
            sent.add(
              'play ${invocation.positionalArguments[0]} '
              'at ${invocation.namedArguments[#playedAt]}',
            );
          });

      awaitFake(async, scrobbleQueue.initialize());
      settle(async);

      expect(sent, [
        'now playing skipped at $skippedAt',
        'now playing song1 at $playedAt',
        'play song1 at $playedAt',
      ]);
      expect(scrobbleQueue.queueSize, 0);
    });

    testInFakeTime('should persist queue to storage', (async) {
      // Make API calls slow so we can queue multiple items
      when(mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
          .thenAnswer((_) async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            throw Exception('Network error');
          });
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            throw Exception('Network error');
          });

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song2', playedAt: DateTime.now()),
      );

      // Wait for processing attempt
      settle(async);

      // Verify queue was persisted
      final prefs = awaitFake(async, SharedPreferences.getInstance());
      final queueJson = prefs.getString('scrobble_queue');
      expect(queueJson, isNotNull);
      expect(queueJson, contains('song1'));
      expect(queueJson, contains('song2'));
    });

    testInFakeTime('should restore queue from storage', (async) {
      // Make API calls slow so we can queue multiple items
      when(mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
          .thenAnswer((_) async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            throw Exception('Network error');
          });
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            throw Exception('Network error');
          });

      // Create and queue requests
      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song2', playedAt: DateTime.now()),
      );

      // Wait for processing attempt (will fail)
      settle(async);

      final originalQueueSize = scrobbleQueue.queueSize;
      expect(originalQueueSize, 2);

      // Dispose and create new queue
      scrobbleQueue.dispose();

      final newQueue = ScrobbleQueue(mockApi);
      awaitFake(async, newQueue.initialize());

      // Queue should be restored
      expect(newQueue.queueSize, originalQueueSize);

      newQueue.dispose();
    });

    testInFakeTime('should process multiple requests in order', (async) {
      final processedSongs = <String>[];

      // Add delay to processing to allow queueing multiple items
      when(mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
          .thenAnswer((invocation) async {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            final songId = invocation.positionalArguments[0] as String;
            processedSongs.add(songId);
          });

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(async, scrobbleQueue.queueNowPlaying('song1'));
      awaitFake(async, scrobbleQueue.queueNowPlaying('song2'));
      awaitFake(async, scrobbleQueue.queueNowPlaying('song3'));

      // Wait for processing
      settle(async);

      expect(processedSongs, ['song1', 'song2', 'song3']);
      expect(scrobbleQueue.queueSize, 0);
    });

    testInFakeTime('should handle mixed request types', (async) {
      // Add delay to processing to allow queueing multiple items
      when(mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
          .thenAnswer((_) async {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          });
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          });

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(async, scrobbleQueue.queueNowPlaying('song1'));
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song2', playedAt: DateTime.now()),
      );
      awaitFake(async, scrobbleQueue.queueNowPlaying('song3'));

      // Wait for processing
      settle(async);

      verify(
        mockApi.scrobbleNowPlaying('song1', startedAt: anyNamed('startedAt')),
      ).called(1);
      verify(
        mockApi.scrobbleSubmission('song2', playedAt: anyNamed('playedAt')),
      ).called(1);
      verify(
        mockApi.scrobbleNowPlaying('song3', startedAt: anyNamed('startedAt')),
      ).called(1);
      expect(scrobbleQueue.queueSize, 0);
    });

    testInFakeTime('should not process when already processing', (async) {
      when(mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
          .thenAnswer((_) async {
            await Future<void>.delayed(const Duration(milliseconds: 500));
          });

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(async, scrobbleQueue.queueNowPlaying('song1'));

      // Try to process multiple times simultaneously
      unawaited(scrobbleQueue.processQueue());
      unawaited(scrobbleQueue.processQueue());
      unawaited(scrobbleQueue.processQueue());

      settle(async);

      // Should only process once
      verify(
        mockApi.scrobbleNowPlaying('song1', startedAt: anyNamed('startedAt')),
      ).called(1);
    });

    testInFakeTime('should handle empty queue gracefully', (async) {
      awaitFake(async, scrobbleQueue.initialize());

      // Process empty queue should not throw
      awaitFake(async, scrobbleQueue.processQueue());

      expect(scrobbleQueue.queueSize, 0);
    });

    testInFakeTime('should clear queue from storage when empty', (async) {
      when(mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
          .thenAnswer((_) async {});

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(async, scrobbleQueue.queueNowPlaying('song1'));

      // Wait for processing
      settle(async);

      // Verify queue was cleared from storage
      final prefs = awaitFake(async, SharedPreferences.getInstance());
      final queueJson = prefs.getString('scrobble_queue');
      expect(queueJson, isNull);
    });

    testInFakeTime('should handle disposal during processing', (async) {
      when(mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
          .thenAnswer((_) async {
            await Future<void>.delayed(const Duration(milliseconds: 500));
          });

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(async, scrobbleQueue.queueNowPlaying('song1'));
      awaitFake(async, scrobbleQueue.queueNowPlaying('song2'));

      // Start processing and dispose immediately
      unawaited(scrobbleQueue.processQueue());
      async.elapse(const Duration(milliseconds: 100));
      scrobbleQueue.dispose();

      // Should not throw, and not send the next one
      settle(async);
      verifyNever(
        mockApi.scrobbleNowPlaying('song2', startedAt: anyNamed('startedAt')),
      );
    });

    test('ScrobbleRequest serialization', () {
      final timestamp = DateTime.now();
      final request = ScrobbleRequest(
        songId: 'test-song',
        type: ScrobbleType.submission,
        playedAt: timestamp,
        queuedAt: timestamp,
      );

      final json = request.toJson();
      final restored = ScrobbleRequest.fromJson(json);

      expect(restored.songId, request.songId);
      expect(restored.type, request.type);
      expect(
        restored.playedAt?.millisecondsSinceEpoch,
        request.playedAt?.millisecondsSinceEpoch,
      );
      expect(
        restored.queuedAt.millisecondsSinceEpoch,
        request.queuedAt.millisecondsSinceEpoch,
      );
    });

    testInFakeTime('should immediately try to process on enqueue', (async) {
      when(mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
          .thenAnswer((_) async {});

      awaitFake(async, scrobbleQueue.initialize());

      // Queue should be processed immediately, without time passing
      awaitFake(async, scrobbleQueue.queueNowPlaying('song1'));
      async.flushMicrotasks();

      verify(
        mockApi.scrobbleNowPlaying('song1', startedAt: anyNamed('startedAt')),
      ).called(1);
      expect(scrobbleQueue.queueSize, 0);
    });

    testInFakeTime('should process queue periodically', (async) {
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) => throw Exception('Network error'));

      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
      );

      // Wait for initial processing attempt (will fail)
      settle(async);

      // Now make the API succeed
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {});

      // The retry timer sends it again after 30 s
      async.elapse(const Duration(seconds: 30));

      // Should have been processed
      verify(
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
      ).called(2);
      expect(scrobbleQueue.queueSize, 0);
    });

    testInFakeTime('clear drops pending requests, also from storage', (async) {
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenThrow(Exception('offline'));
      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      settle(async);

      awaitFake(async, scrobbleQueue.clear());
      settle(async);

      expect(scrobbleQueue.queueSize, 0);
      final prefs = awaitFake(async, SharedPreferences.getInstance());
      expect(prefs.getString('scrobble_queue'), isNull);
    });

    testInFakeTime('clear wins over a pass still in progress', (async) {
      final sending = Completer<void>();
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) => sending.future);
      awaitFake(async, scrobbleQueue.initialize());
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song2', playedAt: DateTime.now()),
      );
      settle(async);

      awaitFake(async, scrobbleQueue.clear());
      sending.complete();
      settle(async);

      final prefs = awaitFake(async, SharedPreferences.getInstance());
      final stored = prefs.getString('scrobble_queue');
      expect(stored == null || (jsonDecode(stored) as List).isEmpty, isTrue);
    });

    testInFakeTime('sends nothing while the server rejects the credentials', (
      async,
    ) {
      when(mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
          .thenAnswer((_) async {});
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {});
      when(mockApi.hasRejectedCredentials).thenReturn(true);
      awaitFake(async, scrobbleQueue.initialize());

      awaitFake(
        async,
        scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      awaitFake(async, scrobbleQueue.queueNowPlaying('song2'));
      for (var i = 0; i < 3; i++) {
        awaitFake(async, scrobbleQueue.processQueue());
      }

      verifyNever(
        mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')),
      );
      verifyNever(
        mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')),
      );
      // Both are kept, also in storage
      expect(scrobbleQueue.queueSize, 2);
      expect(scrobbleQueue.pendingSubmissions, 1);
      final prefs = awaitFake(async, SharedPreferences.getInstance());
      expect(jsonDecode(prefs.getString('scrobble_queue')!), hasLength(2));

      // A new password: sent in order
      when(mockApi.hasRejectedCredentials).thenReturn(false);
      awaitFake(async, scrobbleQueue.processQueue());
      verifyInOrder([
        mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')),
        mockApi.scrobbleNowPlaying('song2', startedAt: anyNamed('startedAt')),
      ]);
      expect(scrobbleQueue.queueSize, 0);
    });
  });

  group('ScrobbleQueue retries', () {
    late MockSubsonicApi mockApi;
    late ScrobbleQueue queue;
    // The fake time of the running test; attempts are recorded in it
    late FakeAsync time;
    final attempts = <Duration>[];
    var offline = true;

    ScrobbleQueue newQueue({
      Duration initial = const Duration(milliseconds: 40),
      Duration max = const Duration(milliseconds: 160),
      void Function()? onSubmitted,
    }) => ScrobbleQueue(
      mockApi,
      onSubmitted: onSubmitted,
      initialRetryDelay: initial,
      maxRetryDelay: max,
    );

    /// A test in fake time whose submissions are recorded in [attempts]
    void retryTest(String description, void Function(FakeAsync async) body) =>
        testInFakeTime(description, (async) {
          time = async;
          body(async);
        });

    setUp(() {
      mockApi = newMockApi();
      SharedPreferences.setMockInitialValues({});
      attempts.clear();
      offline = true;
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {
            attempts.add(time.elapsed);
            if (offline) throw Exception('offline');
          });
    });

    tearDown(() => queue.dispose());

    retryTest('a blocked submission expires after 7 days', (async) {
      var now = DateTime(2026, 1, 1);
      queue = ScrobbleQueue(
        mockApi,
        initialRetryDelay: const Duration(milliseconds: 40),
        maxRetryDelay: const Duration(milliseconds: 160),
        clock: () => now,
      );
      awaitFake(async, queue.initialize());

      awaitFake(async, queue.queueSubmission('song1', playedAt: now));
      async.elapse(const Duration(milliseconds: 20));
      // Still blocked, and kept: the server can't be reached
      expect(queue.queueSize, 1);
      expect(queue.retryScheduled, isTrue);

      final sent = attempts.length;
      now = now.add(const Duration(days: 7, minutes: 1));
      // The retry at 40 ms
      async.elapse(const Duration(milliseconds: 20));

      // Dropped without another attempt
      expect(attempts.length, sent);
      expect(queue.queueSize, 0);
      expect(queue.retryScheduled, isFalse);
    });

    retryTest('an empty queue has no timer', (async) {
      queue = newQueue();
      awaitFake(async, queue.initialize());
      expect(queue.retryScheduled, isFalse);

      offline = false;
      awaitFake(
        async,
        queue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      async.flushMicrotasks();

      expect(queue.queueSize, 0);
      expect(queue.retryScheduled, isFalse);
    });

    retryTest('a failed submission is retried by a timer, at growing delays', (
      async,
    ) {
      queue = newQueue();
      awaitFake(async, queue.initialize());
      awaitFake(
        async,
        queue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      expect(queue.retryScheduled, isTrue);

      // After 40 ms, 80 ms more, then every 160 ms at most
      async.elapse(const Duration(milliseconds: 400));
      expect(attempts, const [
        Duration.zero,
        Duration(milliseconds: 40),
        Duration(milliseconds: 120),
        Duration(milliseconds: 280),
      ]);

      offline = false;
      async.elapse(const Duration(milliseconds: 40));
      expect(attempts.last, const Duration(milliseconds: 440));
      expect(queue.queueSize, 0);
      expect(queue.retryScheduled, isFalse);
    });

    retryTest('the network coming back sends it right away', (async) {
      queue = newQueue(
        initial: const Duration(seconds: 30),
        max: const Duration(minutes: 5),
      );
      awaitFake(async, queue.initialize());
      awaitFake(
        async,
        queue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      expect(attempts, hasLength(1));
      expect(queue.retryScheduled, isTrue);

      offline = false;
      async.elapse(const Duration(seconds: 1));
      queue.networkAvailable();
      async.flushMicrotasks();

      expect(attempts, const [Duration.zero, Duration(seconds: 1)]);
      expect(queue.queueSize, 0);
      expect(queue.retryScheduled, isFalse);
    });

    retryTest('the network coming back with nothing queued does nothing', (
      async,
    ) {
      queue = newQueue();
      awaitFake(async, queue.initialize());

      queue.networkAvailable();
      async.flushMicrotasks();

      expect(attempts, isEmpty);
      expect(queue.retryScheduled, isFalse);
    });

    retryTest('a dispose cancels the timer', (async) {
      queue = newQueue();
      awaitFake(async, queue.initialize());
      awaitFake(
        async,
        queue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      expect(queue.retryScheduled, isTrue);

      queue.dispose();
      async.elapse(const Duration(seconds: 1));

      expect(queue.retryScheduled, isFalse);
      expect(attempts, hasLength(1));
    });

    retryTest('onSubmitted is called for a sent submission only', (async) {
      offline = false;
      when(mockApi.scrobbleNowPlaying(any, startedAt: anyNamed('startedAt')))
          .thenAnswer((_) async {});
      var submitted = 0;
      queue = newQueue(onSubmitted: () => submitted++);
      awaitFake(async, queue.initialize());

      awaitFake(async, queue.queueNowPlaying('song1'));
      async.flushMicrotasks();
      expect(submitted, 0);

      awaitFake(
        async,
        queue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      async.flushMicrotasks();
      expect(submitted, 1);
    });

    retryTest('onSubmitted is not called for a submission that failed', (
      async,
    ) {
      var submitted = 0;
      queue = newQueue(onSubmitted: () => submitted++);
      awaitFake(async, queue.initialize());

      awaitFake(
        async,
        queue.queueSubmission('song1', playedAt: DateTime.now()),
      );
      async.flushMicrotasks();

      expect(submitted, 0);
    });
  });
}
