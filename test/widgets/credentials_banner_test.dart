import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:voidweaver/services/app_state.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:voidweaver/widgets/credentials_banner.dart';

/// Rejects the credentials until [updatePassword] gets [accepted]
class _FakeAppState extends AppState {
  final String accepted;
  bool rejected = true;
  final List<String> attempts = [];

  _FakeAppState(this.accepted);

  @override
  bool get credentialsRejected => rejected;

  @override
  Future<void> updatePassword(String password) async {
    attempts.add(password);
    if (password != accepted) {
      throw const SubsonicException(40, 'Wrong username or password');
    }
    rejected = false;
    notifyListeners();
  }
}

void main() {
  Future<_FakeAppState> pump(WidgetTester tester) async {
    final appState = _FakeAppState('new password');
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: const MaterialApp(home: Scaffold(body: CredentialsBanner())),
    ));
    return appState;
  }

  testWidgets('shows nothing while the credentials are accepted',
      (tester) async {
    final appState = await pump(tester);
    appState.rejected = false;
    appState.notifyListeners();
    await tester.pump();
    expect(find.byType(MaterialBanner), findsNothing);
  });

  testWidgets('updates the password, showing a rejected one as an error',
      (tester) async {
    final appState = await pump(tester);
    expect(find.byType(MaterialBanner), findsOneWidget);

    await tester.tap(find.text('Update password'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    // Empty: the validator refuses it without asking the server
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(find.text('Password is required'), findsOneWidget);
    expect(appState.attempts, isEmpty);

    await tester.enterText(find.byType(TextFormField), 'wrong');
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(find.text('Wrong username or password.'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), 'new password');
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(appState.attempts, ['wrong', 'new password']);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(MaterialBanner), findsNothing);
  });
}
