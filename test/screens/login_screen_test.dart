import 'dart:async';

import 'package:material_ui/material_ui.dart';
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
  Future<void> configure(
    String serverUrl,
    String username,
    String password, {
    bool verifyCredentials = false,
  }) async {
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
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: appState,
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
  }

  Finder field(String label) =>
      find.widgetWithText(TextFormField, label, skipOffstage: false);

  Future<void> fillIn(
    WidgetTester tester, {
    String url = 'https://music.example.com',
    String username = 'alice',
    String password = 'secret',
  }) async {
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
      find.text('URL must use HTTPS protocol for security'),
      findsOneWidget,
    );
    expect(appState.configuredWith, isNull);
  });

  testWidgets('verifies the credentials, trimming all but the password', (
    tester,
  ) async {
    await pumpLogin(tester);
    await fillIn(
      tester,
      url: ' https://music.example.com ',
      username: ' alice ',
      password: ' secret ',
    );
    await tapConnect(tester);

    expect(appState.configuredWith, [
      'https://music.example.com',
      'alice',
      ' secret ',
    ]);
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
      expect(
        tester.widget<TextFormField>(field(label)).enabled,
        isFalse,
        reason: label,
      );
    }

    appState.pending!.complete();
    await tester.pump();
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('shows a failed login once, as a message, not the exception', (
    tester,
  ) async {
    appState.failWith = const SubsonicException(40, 'Wrong username or pw');
    await pumpLogin(tester);
    await fillIn(tester);
    await tapConnect(tester);
    await tester.pumpAndSettle();

    // Above the form, not again in a snackbar
    expect(find.text('Wrong username or password.'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.textContaining('Exception'), findsNothing);
    // The form can be sent again
    expect(find.widgetWithText(ElevatedButton, 'Connect'), findsOneWidget);
  });

  testWidgets('scrolls a failed login\'s message into view', (tester) async {
    // A short window, as with the keyboard open: tapping Connect scrolled
    // the error's place out of view
    tester.view.devicePixelRatio = 2.625;
    tester.view.physicalSize = const Size(1080, 700);
    addTearDown(tester.view.reset);
    appState.failWith = const SubsonicException(40, 'Wrong username or pw');
    await pumpLogin(tester);
    await fillIn(tester);
    await tapConnect(tester);
    await tester.pumpAndSettle();

    final message = find.text('Wrong username or password.');
    final top = tester.getTopLeft(message).dy;
    expect(top, greaterThanOrEqualTo(0));
    expect(top, lessThan(tester.view.physicalSize.height / 2.625));
  });

  TextField textField(WidgetTester tester, String label) => tester.widget(
    find.descendant(of: field(label), matching: find.byType(TextField)),
  );

  testWidgets('sets up the fields for autofill and the keyboard', (
    tester,
  ) async {
    await pumpLogin(tester);

    expect(
      find.ancestor(
        of: field('Username'),
        matching: find.byType(AutofillGroup),
      ),
      findsOneWidget,
    );

    final url = textField(tester, 'Server URL (HTTPS required)');
    expect(url.autofillHints, [AutofillHints.url]);
    expect(url.keyboardType, TextInputType.url);
    expect(url.autocorrect, isFalse);
    expect(url.enableSuggestions, isFalse);
    expect(url.textInputAction, TextInputAction.next);

    final username = textField(tester, 'Username');
    expect(username.autofillHints, [AutofillHints.username]);
    expect(username.autocorrect, isFalse);
    expect(username.enableSuggestions, isFalse);
    expect(username.textInputAction, TextInputAction.next);

    final password = textField(tester, 'Password');
    expect(password.autofillHints, [AutofillHints.password]);
    expect(password.obscureText, isTrue);
    expect(password.textInputAction, TextInputAction.done);
  });

  testWidgets('Next moves on to the following field', (tester) async {
    await pumpLogin(tester);
    await tester.enterText(field('Server URL (HTTPS required)'), 'https://a');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();

    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(
      focused.findAncestorWidgetOfExactType<TextFormField>()?.controller,
      tester.widget<TextFormField>(field('Username')).controller,
    );
  });

  testWidgets('Done on the password logs in', (tester) async {
    await pumpLogin(tester);
    await fillIn(tester);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(appState.configuredWith, [
      'https://music.example.com',
      'alice',
      'secret',
    ]);
  });

  bool autofillCommitted(WidgetTester tester) => tester.testTextInput.log.any(
    (call) =>
        call.method == 'TextInput.finishAutofillContext' &&
        call.arguments == true,
  );

  testWidgets('lets the password manager save a login that worked', (
    tester,
  ) async {
    await pumpLogin(tester);
    await fillIn(tester);
    tester.testTextInput.log.clear();
    await tapConnect(tester);
    await tester.pump();

    expect(autofillCommitted(tester), isTrue);
  });

  testWidgets('asks to save before the screen is replaced', (tester) async {
    // Like the app's router: the home screen replaces the login screen once
    // the login worked, which disposes its autofill group
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: appState,
        child: MaterialApp(
          home: Consumer<AppState>(
            builder: (context, state, _) =>
                state.configurationLoadingState == LoadingState.success
                ? const Text('home')
                : const LoginScreen(),
          ),
        ),
      ),
    );
    await fillIn(tester);
    tester.testTextInput.log.clear();
    await tapConnect(tester);
    await tester.pump();

    expect(find.text('home'), findsOneWidget);
    final finishes = [
      for (final call in tester.testTextInput.log)
        if (call.method == 'TextInput.finishAutofillContext') call.arguments,
    ];
    // The save first; the group's cancel on dispose comes too late to undo it
    expect(finishes.first, isTrue);
  });

  testWidgets('doesn\'t offer to save a login that failed', (tester) async {
    appState.failWith = const SubsonicException(40, 'Wrong username or pw');
    await pumpLogin(tester);
    await fillIn(tester);
    tester.testTextInput.log.clear();
    await tapConnect(tester);
    await tester.pumpAndSettle();
    // Nor when the screen goes away
    await tester.pumpWidget(const SizedBox());

    expect(autofillCommitted(tester), isFalse);
  });
}
