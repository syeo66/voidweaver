import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver/widgets/error_boundary.dart';

void main() {
  group('ErrorBoundary Tests', () {
    testWidgets('should display child widget when no error occurs',
        (WidgetTester tester) async {
      const testText = 'Test Child Widget';

      await tester.pumpWidget(
        const MaterialApp(
          home: ErrorBoundary(
            child: Text(testText),
          ),
        ),
      );

      expect(find.text(testText), findsOneWidget);
      expect(find.byType(ErrorDisplay), findsNothing);
    });

    testWidgets('should show error UI when provided',
        (WidgetTester tester) async {
      // Test the ErrorDisplay widget directly instead of triggering errors
      final errorDetails = FlutterErrorDetails(
        exception: Exception('Test error'),
        library: 'test',
        context: ErrorDescription('Test context'),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: false),
          home: Scaffold(
            body: ErrorDisplay(
              error: errorDetails,
              message: 'Custom error message',
            ),
          ),
        ),
      );

      expect(find.text('Something went wrong'), findsOneWidget);
      expect(find.text('Custom error message'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });
  });

  group('ErrorBoundary with build errors', () {
    /// Installs the boundaries' error widget for the test body; the test
    /// binding requires the original builder back at the end.
    Future<void> withBoundaries(Future<void> Function() body) async {
      final builder = ErrorWidget.builder;
      ErrorBoundary.install();
      try {
        await body();
      } finally {
        ErrorWidget.builder = builder;
      }
    }

    /// Lets the boundary switch to its fallback (after the frame), and
    /// consumes the build error, which the test binding records.
    Future<void> pumpError(WidgetTester tester) async {
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isA<StateError>());
    }

    testWidgets('shows its fallback when a widget in it fails', (tester) async {
      await withBoundaries(() async {
        await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
            body: ErrorBoundary(
              errorMessage: 'Albums failed',
              child: _Thrower(),
            ),
          ),
        ));
        await pumpError(tester);

        expect(find.text('Albums failed'), findsOneWidget);
      });
    });

    testWidgets('leaves the rest of the app and FlutterError.onError alone',
        (tester) async {
      await withBoundaries(() async {
        final onError = FlutterError.onError;
        await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
            body: Column(children: [
              ErrorBoundary(errorMessage: 'First failed', child: _Thrower()),
              ErrorBoundary(
                  errorMessage: 'Second failed', child: Text('Second')),
              Text('Outside'),
            ]),
          ),
        ));
        await pumpError(tester);

        expect(find.text('First failed'), findsOneWidget);
        expect(find.text('Second'), findsOneWidget);
        expect(find.text('Second failed'), findsNothing);
        expect(find.text('Outside'), findsOneWidget);
        expect(FlutterError.onError, same(onError));
      });
    });

    testWidgets('the innermost boundary takes the error', (tester) async {
      await withBoundaries(() async {
        await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
            body: ErrorBoundary(
              errorMessage: 'Outer failed',
              child: ErrorBoundary(
                errorMessage: 'Inner failed',
                child: _Thrower(),
              ),
            ),
          ),
        ));
        await pumpError(tester);

        expect(find.text('Inner failed'), findsOneWidget);
        expect(find.text('Outer failed'), findsNothing);
      });
    });

    testWidgets('reports the error once and uses the fallback builder',
        (tester) async {
      await withBoundaries(() async {
        final reported = <FlutterErrorDetails>[];
        await tester.pumpWidget(MaterialApp(
          home: ErrorBoundary(
            onError: reported.add,
            fallbackBuilder: (error) => Text('Fallback: ${error.exception}'),
            child: const _Thrower(),
          ),
        ));
        await pumpError(tester);

        expect(reported, hasLength(1));
        expect(find.text('Fallback: Bad state: broken'), findsOneWidget);
      });
    });

    testWidgets('Try Again builds the child again', (tester) async {
      await withBoundaries(() async {
        _Thrower.broken = true;
        addTearDown(() => _Thrower.broken = true);
        await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: ErrorBoundary(child: _Thrower())),
        ));
        await pumpError(tester);

        _Thrower.broken = false;
        await tester.tap(find.text('Try Again'));
        await tester.pump();

        expect(find.text('Working'), findsOneWidget);
        expect(find.byType(ErrorDisplay), findsNothing);
      });
    });
  });

  group('ErrorDisplay Tests', () {
    testWidgets('should display error information correctly',
        (WidgetTester tester) async {
      const errorMessage = 'Test error message';
      final errorDetails = FlutterErrorDetails(
        exception: Exception('Test exception'),
        library: 'test',
        context: ErrorDescription('Test context'),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: false),
          home: Scaffold(
            body: ErrorDisplay(
              error: errorDetails,
              message: errorMessage,
            ),
          ),
        ),
      );

      expect(find.text('Something went wrong'), findsOneWidget);
      expect(find.text(errorMessage), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('should show retry button when onRetry is provided',
        (WidgetTester tester) async {
      bool retryPressed = false;
      final errorDetails = FlutterErrorDetails(
        exception: Exception('Test exception'),
        library: 'test',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: false),
          home: Scaffold(
            body: ErrorDisplay(
              error: errorDetails,
              onRetry: () {
                retryPressed = true;
              },
            ),
          ),
        ),
      );

      expect(find.text('Try Again'), findsOneWidget);

      await tester.tap(find.text('Try Again'));
      expect(retryPressed, isTrue);
    });

    testWidgets(
        'should show error details in debug mode when showDetails is true',
        (WidgetTester tester) async {
      final errorDetails = FlutterErrorDetails(
        exception: Exception('Detailed test exception'),
        library: 'test',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: false),
          home: Scaffold(
            body: ErrorDisplay(
              error: errorDetails,
              showDetails: true,
            ),
          ),
        ),
      );

      if (kDebugMode) {
        expect(find.text('Error Details'), findsOneWidget);

        // Tap to expand details
        await tester.tap(find.text('Error Details'));
        await tester.pumpAndSettle();

        // Look for the error text in any form
        expect(find.textContaining('Exception'), findsOneWidget);
      } else {
        // In release mode, error details should not be shown
        expect(find.text('Error Details'), findsNothing);
      }
    });
  });

  group('ErrorBoundary Extension Tests', () {
    testWidgets('withErrorBoundary extension should wrap widget',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: const Text('Test Widget').withErrorBoundary(
            errorMessage: 'Extension error message',
          ),
        ),
      );

      expect(find.text('Test Widget'), findsOneWidget);
      expect(find.byType(ErrorBoundary), findsOneWidget);
    });
  });
}

/// Fails to build while [broken] is set.
class _Thrower extends StatelessWidget {
  static bool broken = true;

  const _Thrower();

  @override
  Widget build(BuildContext context) {
    if (broken) throw StateError('broken');
    return const Text('Working');
  }
}
