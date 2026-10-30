import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:voidweaver/screens/login_screen.dart';
import 'package:voidweaver/services/app_state.dart';
import 'package:voidweaver/services/network_errors.dart';
import 'package:voidweaver/services/subsonic_api.dart';

/// An [AppState] whose [configure] records the login instead of contacting a
/// server, and fails with [failWith] or waits for [pending] if set.
class _FakeAppState extends AppState {
  LoadingState _state = LoadingState.idle;
  String? _error;
  Object? failWith;
  Completer<void>? pending;
  List<String>? configuredWith;
  bool? verified;

  @override
  LoadingState get configurationLoadingState => _state;

  @override
  String? get configurationError => _error;

  @override
  Future<void> configure(String serverUrl, String username, String password,
      {bool verifyCredentials = false}) async {
    configuredWith = [serverUrl, username, password];
    verified = verifyCredentials;
    _state = LoadingState.loading;
    _error = null;
    notifyListeners();
    await pending?.future;
    final error = failWith;
    if (error != null) {
      _state = LoadingState.error;
      _error = NetworkErrorHelper.getErrorMessage(error);
      notifyListeners();
      throw error;
    }
    _state = LoadingState.success;
    notifyListeners();
  }
}

/// Sets the screen to a phone's size (Pixel 8) in [orientation].
void _setOrientation(WidgetTester tester, Orientation orientation) {
  tester.view.devicePixelRatio = 2.625;
  tester.view.physicalSize = orientation == Orientation.portrait
      ? const Size(1080, 2400)
      : const Size(2400, 1080);
  addTearDown(tester.view.reset);
}

void main() {
  late _FakeAppState appState;

  setUp(() => appState = _FakeAppState());

  Future<void> pumpLogin(WidgetTester tester) async {
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: const MaterialApp(home: LoginScreen()),
    ));
  }

  Finder field(String label) =>
      find.widgetWithText(TextFormField, label, skipOffstage: false);

  Future<void> fillIn(WidgetTester tester,
      {String url = 'https://music.example.com',
      String username = 'alice',
      String password = 'secret'}) async {
    await tester.enterText(field('Server URL (HTTPS required)'), url);
    await tester.enterText(field('Username'), username);
    await tester.enterText(field('Password'), password);
  }

  Future<void> tapConnect(WidgetTester tester) async {
    final button = find.widgetWithText(ElevatedButton, 'Connect');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
  }

  for (final orientation in Orientation.values) {
    testWidgets('lays out the form in ${orientation.name}', (tester) async {
      _setOrientation(tester, orientation);
      await pumpLogin(tester);

      // An overflow would fail the test
      expect(field('Server URL (HTTPS required)'), findsOneWidget);
      expect(field('Username'), findsOneWidget);
      expect(field('Password'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Connect'), findsOneWidget);
    });
  }

  testWidgets('requires every field', (tester) async {
    await pumpLogin(tester);
    await tapConnect(tester);

    expect(find.text('Server URL is required'), findsOneWidget);
    expect(find.text('Username is required'), findsOneWidget);
    expect(find.text('Password is required'), findsOneWidget);
    expect(appState.configuredWith, isNull);
  });

  testWidgets('rejects an http:// URL', (tester) async {
    await pumpLogin(tester);
    await fillIn(tester, url: 'http://music.example.com');
    await tapConnect(tester);

    expect(
        find.text('URL must use HTTPS protocol for security'), findsOneWidget);
    expect(appState.configuredWith, isNull);
  });

  testWidgets('verifies the credentials, trimming all but the password',
      (tester) async {
    await pumpLogin(tester);
    await fillIn(tester,
        url: ' https://music.example.com ',
        username: ' alice ',
        password: ' secret ');
    await tapConnect(tester);

    expect(appState.configuredWith,
        ['https://music.example.com', 'alice', ' secret ']);
    expect(appState.verified, isTrue);
  });

  testWidgets('disables the form while connecting', (tester) async {
    appState.pending = Completer();
    await pumpLogin(tester);
    await fillIn(tester);
    await tapConnect(tester);

    expect(find.text('Connecting...'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button.onPressed, isNull);
    for (final label in [
      'Server URL (HTTPS required)',
      'Username',
      'Password',
    ]) {
      expect(tester.widget<TextFormField>(field(label)).enabled, isFalse,
          reason: label);
    }

    appState.pending!.complete();
    await tester.pump();
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('shows a failed login as a message, not the exception',
      (tester) async {
    appState.failWith = const SubsonicException(40, 'Wrong username or pw');
    await pumpLogin(tester);
    await fillIn(tester);
    await tapConnect(tester);
    await tester.pump(); // the snackbar

    // In the form and in the snackbar
    expect(find.text('Wrong username or password.'), findsOneWidget);
    expect(find.text('Connection failed: Wrong username or password.'),
        findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
    // The form can be sent again
    expect(find.widgetWithText(ElevatedButton, 'Connect'), findsOneWidget);
  });
}
