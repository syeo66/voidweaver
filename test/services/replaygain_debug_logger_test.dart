import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/replaygain_debug_logger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('rg_debug_log_test');
    addTearDown(() => temp.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => temp.path);
  });

  test('masks credentials in every line it writes', () async {
    final logger = ReplayGainDebugLogger.instance;
    await logger.initialize();
    await logger.setEnabled(true);
    addTearDown(() => logger.setEnabled(false));

    logger.log('Stream URL: https://music.example/rest/stream'
        '?u=alice&t=0123abcd&s=salty&v=1.16.1&id=42');
    logger.log('Error: ClientException: Connection reset, '
        'uri=https://music.example/rest/stream?u=alice&t=0123abcd&s=salty');
    await logger.flush();

    final text = await File('${temp.path}/replaygain_debug.log').readAsString();
    expect(text, contains('id=42'));
    expect(text, contains('Connection reset'));
    expect(text, isNot(contains('alice')));
    expect(text, isNot(contains('0123abcd')));
    expect(text, isNot(contains('salty')));
  });
}
