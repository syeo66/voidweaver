import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:voidweaver/widgets/app_version.dart';

void main() {
  testWidgets('shows the version and build number', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'voidweaver',
      packageName: 'com.example.voidweaver',
      version: '1.1.0',
      buildNumber: '160',
      buildSignature: '',
    );

    await tester.pumpWidget(const MaterialApp(home: AppVersion()));
    await tester.pumpAndSettle();

    expect(find.text('Voidweaver 1.1.0 (160)'), findsOneWidget);
  });
}
