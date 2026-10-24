import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/scrobble_queue.dart';
import 'package:voidweaver/services/subsonic_api.dart';

import '../test_helpers/mocks.mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScrobbleQueue Tests', () {
    late MockSubsonicApi mockApi;
    late ScrobbleQueue scrobbleQueue;

    setUp(() async {
      mockApi = MockSubsonicApi();
      SharedPreferences.setMockInitialValues({});
      scrobbleQueue = ScrobbleQueue(mockApi);
    });

    tearDown(() {
      scrobbleQueue.dispose();
    });

    test('should initialize with empty queue', () async {
      await scrobbleQueue.initialize();
      expect(scrobbleQueue.queueSize, 0);
    });

    test('should queue now playing notification', () async {
      when(mockApi.scrobbleNowPlaying(any))
          .thenAnswer((_) => Future.delayed(const Duration(milliseconds: 100)));
      await scrobbleQueue.initialize();

      await scrobbleQueue.queueNowPlaying('song1');

      expect(scrobbleQueue.queueSize, 1);
    });

    test('should queue scrobble submission', () async {
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) => Future.delayed(const Duration(milliseconds: 100)));
      await scrobbleQueue.initialize();

      await scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now());

      expect(scrobbleQueue.queueSize, 1);
    });

    test('should process now playing request successfully', () async {
      when(mockApi.scrobbleNowPlaying(any)).thenAnswer((_) async {});

      await scrobbleQueue.initialize();
      await scrobbleQueue.queueNowPlaying('song1');

      // Wait for processing
      await Future.delayed(const Duration(milliseconds: 300));

      verify(mockApi.scrobbleNowPlaying('song1')).called(1);
      expect(scrobbleQueue.queueSize, 0);
    });

    test('should process submission request successfully', () async {
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {});

      await scrobbleQueue.initialize();
      final timestamp = DateTime.now();
      await scrobbleQueue.queueSubmission('song1', playedAt: timestamp);

      // Wait for processing
      await Future.delayed(const Duration(milliseconds: 300));

      verify(mockApi.scrobbleSubmission('song1', playedAt: timestamp))
          .called(1);
      expect(scrobbleQueue.queueSize, 0);
    });

    test('should retry failed submissions', () async {
      var callCount = 0;
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {
        callCount++;
        if (callCount <= 2) {
          throw Exception('Network error');
        }
      });

      await scrobbleQueue.initialize();
      await scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now());
      await Future.delayed(const Duration(milliseconds: 300));
      expect(scrobbleQueue.queueSize, 1);

      await scrobbleQueue.processQueue();
      expect(scrobbleQueue.queueSize, 1);

      await scrobbleQueue.processQueue();
      verify(mockApi.scrobbleSubmission('song1',
              playedAt: anyNamed('playedAt')))
          .called(3);
      expect(scrobbleQueue.queueSize, 0);
    });

    test('should not retry right away after a failure', () async {
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenThrow(Exception('Network error'));

      await scrobbleQueue.initialize();
      await scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now());
      await Future.delayed(const Duration(seconds: 1));

      // Retried by the 30 s timer, not in a loop
      verify(mockApi.scrobbleSubmission('song1',
              playedAt: anyNamed('playedAt')))
          .called(1);
      expect(scrobbleQueue.queueSize, 1);
    });

    test('should keep a submission through repeated network failures',
        () async {
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenThrow(Exception('Network error'));

      await scrobbleQueue.initialize();
      await scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now());
      for (var i = 0; i < 10; i++) {
        await scrobbleQueue.processQueue();
      }

      // Only dropped once it's older than 7 days
      expect(scrobbleQueue.queueSize, 1);
    });

    test('should keep later requests behind a failed submission', () async {
      final sent = <String>[];
      var online = false;
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((invocation) async {
        if (!online) throw Exception('Network error');
        sent.add(invocation.positionalArguments[0] as String);
      });

      await scrobbleQueue.initialize();
      await scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now());
      await scrobbleQueue.queueSubmission('song2', playedAt: DateTime.now());
      await Future.delayed(const Duration(milliseconds: 300));

      // song2 wasn't tried while song1 was failing
      verifyNever(
          mockApi.scrobbleSubmission('song2', playedAt: anyNamed('playedAt')));
      expect(scrobbleQueue.queueSize, 2);

      online = true;
      await scrobbleQueue.processQueue();
      expect(sent, ['song1', 'song2']);
      expect(scrobbleQueue.queueSize, 0);
    });

    test('should drop a now playing notification that fails', () async {
      when(mockApi.scrobbleNowPlaying(any))
          .thenThrow(Exception('Network error'));

      await scrobbleQueue.initialize();
      await scrobbleQueue.queueNowPlaying('song1');
      await Future.delayed(const Duration(milliseconds: 300));

      expect(scrobbleQueue.queueSize, 0);
    });

    test('should drop a submission the server rejects', () async {
      when(mockApi.scrobbleSubmission('song1', playedAt: anyNamed('playedAt')))
          .thenThrow(const SubsonicException(70, 'Song not found'));
      when(mockApi.scrobbleSubmission('song2', playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {});

      await scrobbleQueue.initialize();
      await scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now());
      await scrobbleQueue.queueSubmission('song2', playedAt: DateTime.now());
      await Future.delayed(const Duration(milliseconds: 500));

      verify(mockApi.scrobbleSubmission('song2',
              playedAt: anyNamed('playedAt')))
          .called(1);
      expect(scrobbleQueue.queueSize, 0);
    });

    test('should keep a submission refused because of the credentials',
        () async {
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenThrow(const SubsonicException(40, 'Wrong username or password'));

      await scrobbleQueue.initialize();
      await scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now());
      await Future.delayed(const Duration(milliseconds: 300));

      expect(scrobbleQueue.queueSize, 1);
    });

    test('should drop requests older than 7 days', () async {
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

      await scrobbleQueue.initialize();
      await scrobbleQueue.processQueue();

      verifyNever(
          mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')));
      expect(scrobbleQueue.queueSize, 0);
    });

    test('should persist queue to storage', () async {
      // Make API calls slow so we can queue multiple items
      when(mockApi.scrobbleNowPlaying(any)).thenAnswer((_) async {
        await Future.delayed(const Duration(milliseconds: 100));
        throw Exception('Network error');
      });
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {
        await Future.delayed(const Duration(milliseconds: 100));
        throw Exception('Network error');
      });

      await scrobbleQueue.initialize();
      await scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now());
      await scrobbleQueue.queueSubmission('song2', playedAt: DateTime.now());

      // Wait for processing attempt
      await Future.delayed(const Duration(milliseconds: 500));

      // Verify queue was persisted
      final prefs = await SharedPreferences.getInstance();
      final queueJson = prefs.getString('scrobble_queue');
      expect(queueJson, isNotNull);
      expect(queueJson, contains('song1'));
      expect(queueJson, contains('song2'));
    });

    test('should restore queue from storage', () async {
      // Make API calls slow so we can queue multiple items
      when(mockApi.scrobbleNowPlaying(any)).thenAnswer((_) async {
        await Future.delayed(const Duration(milliseconds: 100));
        throw Exception('Network error');
      });
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {
        await Future.delayed(const Duration(milliseconds: 100));
        throw Exception('Network error');
      });

      // Create and queue requests
      await scrobbleQueue.initialize();
      await scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now());
      await scrobbleQueue.queueSubmission('song2', playedAt: DateTime.now());

      // Wait for processing attempt (will fail)
      await Future.delayed(const Duration(milliseconds: 500));

      final originalQueueSize = scrobbleQueue.queueSize;
      expect(originalQueueSize, 2);

      // Dispose and create new queue
      scrobbleQueue.dispose();

      final newQueue = ScrobbleQueue(mockApi);
      await newQueue.initialize();

      // Queue should be restored
      expect(newQueue.queueSize, originalQueueSize);

      newQueue.dispose();
    });

    test('should process multiple requests in order', () async {
      final processedSongs = <String>[];

      // Add delay to processing to allow queueing multiple items
      when(mockApi.scrobbleNowPlaying(any)).thenAnswer((invocation) async {
        await Future.delayed(const Duration(milliseconds: 50));
        final songId = invocation.positionalArguments[0] as String;
        processedSongs.add(songId);
      });

      await scrobbleQueue.initialize();
      await scrobbleQueue.queueNowPlaying('song1');
      await scrobbleQueue.queueNowPlaying('song2');
      await scrobbleQueue.queueNowPlaying('song3');

      // Wait for processing
      await Future.delayed(const Duration(milliseconds: 800));

      expect(processedSongs, ['song1', 'song2', 'song3']);
      expect(scrobbleQueue.queueSize, 0);
    });

    test('should handle mixed request types', () async {
      // Add delay to processing to allow queueing multiple items
      when(mockApi.scrobbleNowPlaying(any)).thenAnswer((_) async {
        await Future.delayed(const Duration(milliseconds: 50));
      });
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {
        await Future.delayed(const Duration(milliseconds: 50));
      });

      await scrobbleQueue.initialize();
      await scrobbleQueue.queueNowPlaying('song1');
      await scrobbleQueue.queueSubmission('song2', playedAt: DateTime.now());
      await scrobbleQueue.queueNowPlaying('song3');

      // Wait for processing
      await Future.delayed(const Duration(milliseconds: 800));

      verify(mockApi.scrobbleNowPlaying('song1')).called(1);
      verify(mockApi.scrobbleSubmission('song2',
              playedAt: anyNamed('playedAt')))
          .called(1);
      verify(mockApi.scrobbleNowPlaying('song3')).called(1);
      expect(scrobbleQueue.queueSize, 0);
    });

    test('should not process when already processing', () async {
      when(mockApi.scrobbleNowPlaying(any)).thenAnswer((_) async {
        await Future.delayed(const Duration(milliseconds: 500));
      });

      await scrobbleQueue.initialize();
      await scrobbleQueue.queueNowPlaying('song1');

      // Try to process multiple times simultaneously
      unawaited(scrobbleQueue.processQueue());
      unawaited(scrobbleQueue.processQueue());
      unawaited(scrobbleQueue.processQueue());

      await Future.delayed(const Duration(milliseconds: 700));

      // Should only process once
      verify(mockApi.scrobbleNowPlaying('song1')).called(1);
    });

    test('should handle empty queue gracefully', () async {
      await scrobbleQueue.initialize();

      // Process empty queue should not throw
      await scrobbleQueue.processQueue();

      expect(scrobbleQueue.queueSize, 0);
    });

    test('should clear queue from storage when empty', () async {
      when(mockApi.scrobbleNowPlaying(any)).thenAnswer((_) async {});

      await scrobbleQueue.initialize();
      await scrobbleQueue.queueNowPlaying('song1');

      // Wait for processing
      await Future.delayed(const Duration(milliseconds: 300));

      // Verify queue was cleared from storage
      final prefs = await SharedPreferences.getInstance();
      final queueJson = prefs.getString('scrobble_queue');
      expect(queueJson, isNull);
    });

    test('should handle disposal during processing', () async {
      when(mockApi.scrobbleNowPlaying(any)).thenAnswer((_) async {
        await Future.delayed(const Duration(milliseconds: 500));
      });

      await scrobbleQueue.initialize();
      await scrobbleQueue.queueNowPlaying('song1');
      await scrobbleQueue.queueNowPlaying('song2');

      // Start processing and dispose immediately
      unawaited(scrobbleQueue.processQueue());
      await Future.delayed(const Duration(milliseconds: 100));
      scrobbleQueue.dispose();

      // Should not throw
      await Future.delayed(const Duration(milliseconds: 600));
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
      expect(restored.playedAt?.millisecondsSinceEpoch,
          request.playedAt?.millisecondsSinceEpoch);
      expect(restored.queuedAt.millisecondsSinceEpoch,
          request.queuedAt.millisecondsSinceEpoch);
    });

    test('should immediately try to process on enqueue', () async {
      when(mockApi.scrobbleNowPlaying(any)).thenAnswer((_) async {});

      await scrobbleQueue.initialize();

      // Queue should be processed immediately
      await scrobbleQueue.queueNowPlaying('song1');

      // Small delay for immediate processing
      await Future.delayed(const Duration(milliseconds: 200));

      verify(mockApi.scrobbleNowPlaying('song1')).called(1);
      expect(scrobbleQueue.queueSize, 0);
    });

    test('should process queue periodically', () async {
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) => throw Exception('Network error'));

      await scrobbleQueue.initialize();
      await scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now());

      // Wait for initial processing attempt (will fail)
      await Future.delayed(const Duration(milliseconds: 300));

      // Now make the API succeed
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) async {});

      // Wait for periodic processing (up to 30 seconds interval, but we'll manually trigger)
      await scrobbleQueue.processQueue();
      await Future.delayed(const Duration(milliseconds: 300));

      // Should have been processed
      verify(mockApi.scrobbleSubmission('song1',
              playedAt: anyNamed('playedAt')))
          .called(2);
      expect(scrobbleQueue.queueSize, 0);
    });

    test('clear drops pending requests, also from storage', () async {
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenThrow(Exception('offline'));
      await scrobbleQueue.initialize();
      await scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now());
      await Future.delayed(const Duration(milliseconds: 50));

      await scrobbleQueue.clear();
      await Future.delayed(const Duration(milliseconds: 50));

      expect(scrobbleQueue.queueSize, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('scrobble_queue'), isNull);
    });

    test('clear wins over a pass still in progress', () async {
      final sending = Completer<void>();
      when(mockApi.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
          .thenAnswer((_) => sending.future);
      await scrobbleQueue.initialize();
      await scrobbleQueue.queueSubmission('song1', playedAt: DateTime.now());
      await scrobbleQueue.queueSubmission('song2', playedAt: DateTime.now());
      await Future.delayed(const Duration(milliseconds: 50));

      await scrobbleQueue.clear();
      sending.complete();
      await Future.delayed(const Duration(milliseconds: 200));

      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('scrobble_queue');
      expect(stored == null || (jsonDecode(stored) as List).isEmpty, isTrue);
    });
  });
}
