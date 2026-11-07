import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:voidweaver/services/network_config.dart';
import 'package:voidweaver/services/network_retry.dart';

void main() {
  final uri = Uri.parse('https://example.test/rest/ping');
  const config = NetworkConfig(
    maxRetryAttempts: 3,
    initialRetryDelay: Duration(milliseconds: 1),
    maxRetryDelay: Duration(milliseconds: 5),
    metadataTimeout: Duration(milliseconds: 50),
  );

  NetworkRetryService serviceFor(http.Client client) =>
      NetworkRetryService(config: config, httpClient: client);

  group('status codes', () {
    test('retries a gateway error and returns the later answer', () async {
      final statuses = [502, 503, 200];
      var requests = 0;
      final service = serviceFor(
        MockClient((request) async {
          return http.Response('body', statuses[requests++]);
        }),
      );

      final response = await service.getWithRetry(uri);

      expect(response.statusCode, 200);
      expect(response.body, 'body');
      expect(requests, 3);
    });

    test('throws the status once the attempts are used up', () async {
      var requests = 0;
      final service = serviceFor(
        MockClient((request) async {
          requests++;
          return http.Response('', 503);
        }),
      );

      await expectLater(
        service.getWithRetry(uri),
        throwsA(
          isA<HttpStatusException>().having((e) => e.statusCode, 'status', 503),
        ),
      );
      expect(requests, config.maxRetryAttempts);
    });

    test('does not retry other statuses', () async {
      var requests = 0;
      final service = serviceFor(
        MockClient((request) async {
          requests++;
          return http.Response('', 404);
        }),
      );

      await expectLater(
        service.getWithRetry(uri),
        throwsA(
          isA<HttpStatusException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
      expect(requests, 1);
    });

    test('without retry a gateway error is sent once', () async {
      var requests = 0;
      final service = serviceFor(
        MockClient((request) async {
          requests++;
          return http.Response('', 502);
        }),
      );

      await expectLater(
        service.getWithRetry(uri, retry: false),
        throwsA(isA<HttpStatusException>()),
      );
      expect(requests, 1);
    });

    test('sends the headers', () async {
      String? agent;
      final service = serviceFor(
        MockClient((request) async {
          agent = request.headers['User-Agent'];
          return http.Response('', 200);
        }),
      );

      await service.getWithRetry(uri, headers: {'User-Agent': 'voidweaver'});

      expect(agent, 'voidweaver');
    });
  });

  group('timeouts', () {
    test('a request that times out is aborted, then retried', () async {
      final aborted = <int>[];
      var requests = 0;
      final service = serviceFor(
        MockClient.streaming((request, body) async {
          final attempt = ++requests;
          if (attempt == 1) {
            // Never answers, like a stalled connection
            final trigger = (request as http.Abortable).abortTrigger!;
            unawaited(trigger.then((_) => aborted.add(attempt)));
            return Completer<http.StreamedResponse>().future;
          }
          return http.StreamedResponse(Stream.value([1, 2, 3]), 200);
        }),
      );

      final response = await service.getWithRetry(
        uri,
        requestType: NetworkRequestType.metadata,
      );

      expect(response.bodyBytes, [1, 2, 3]);
      expect(requests, 2);
      expect(aborted, [1]);
    });

    test('a body that stalls times out too', () async {
      var aborted = false;
      final service = serviceFor(
        MockClient.streaming((request, body) async {
          final trigger = (request as http.Abortable).abortTrigger!;
          unawaited(trigger.then((_) => aborted = true));
          // Headers arrive, the body never ends
          return http.StreamedResponse(
            StreamController<List<int>>().stream,
            200,
          );
        }),
      );

      await expectLater(
        service.getWithRetry(
          uri,
          requestType: NetworkRequestType.metadata,
          retry: false,
        ),
        throwsA(isA<NetworkTimeoutException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(aborted, isTrue);
    });

    test('a request that answers in time is not aborted', () async {
      var aborted = false;
      final service = serviceFor(
        MockClient.streaming((request, body) async {
          final trigger = (request as http.Abortable).abortTrigger!;
          unawaited(trigger.then((_) => aborted = true));
          return http.StreamedResponse(Stream.value([1]), 200);
        }),
      );

      await service.getWithRetry(uri);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(aborted, isFalse);
    });
  });

  group('other errors', () {
    test('are rethrown with the stack trace of where they happened', () async {
      final service = serviceFor(MockClient((request) => _failInClient()));

      Object? error;
      StackTrace? stackTrace;
      try {
        await service.getWithRetry(uri);
      } catch (e, s) {
        error = e;
        stackTrace = s;
      }

      expect(error, isA<FormatException>());
      expect(stackTrace.toString(), contains('_failInClient'));
    });
  });
}

Future<http.Response> _failInClient() async =>
    throw const FormatException('not a response');
