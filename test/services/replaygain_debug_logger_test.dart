import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/replaygain_debug_logger.dart';
import 'package:voidweaver/services/replaygain_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // One directory for all tests: the logger is a singleton, which keeps the
  // log file's path once it has asked for it
  late Directory temp;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('rg_debug_log_test');
  });
  tearDownAll(() => temp.delete(recursive: true));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => temp.path,
        );
    await ReplayGainDebugLogger.instance.clear();
  });

  test('masks credentials in every line it writes', () async {
    final logger = ReplayGainDebugLogger.instance;
    await logger.initialize();
    await logger.setEnabled(true);
    addTearDown(() => logger.setEnabled(false));

    logger.log(
      'Stream URL: https://music.example/rest/stream'
      '?u=alice&t=0123abcd&s=salty&v=1.16.1&id=42',
    );
    logger.log(
      'Error: ClientException: Connection reset, '
      'uri=https://music.example/rest/stream?u=alice&t=0123abcd&s=salty',
    );
    await logger.flush();

    final text = await File('${temp.path}/replaygain_debug.log').readAsString();
    expect(text, contains('id=42'));
    expect(text, contains('Connection reset'));
    expect(text, isNot(contains('alice')));
    expect(text, isNot(contains('0123abcd')));
    expect(text, isNot(contains('salty')));
  });

  test('logReplayGain builds no line while logging is off', () async {
    final logger = ReplayGainDebugLogger.instance;
    await logger.initialize();
    // Tests don't call setUpLogging(), so the console takes no FINE lines
    expect(replayGainLogging, isFalse);

    var built = 0;
    logReplayGain(() {
      built++;
      return 'line';
    });
    expect(built, 0);

    await logger.setEnabled(true);
    addTearDown(() => logger.setEnabled(false));
    logReplayGain(() {
      built++;
      return 'line';
    });
    expect(built, 1);
  });

  test('lines of a parse in the background reach the debug log', () async {
    final logger = ReplayGainDebugLogger.instance;
    await logger.initialize();
    await logger.setEnabled(true);
    addTearDown(() => logger.setEnabled(false));

    // A FLAC stream with a Vorbis comment
    final comment = 'REPLAYGAIN_TRACK_GAIN=-6.50 dB'.codeUnits;
    final bytes = Uint8List.fromList([
      ...'fLaC'.codeUnits,
      0x84, 0, 0, comment.length, // last block: VORBIS_COMMENT
      ...comment,
    ]);
    final data = await ReplayGainReader.readFromHead((_) async => bytes);
    await logger.flush();

    expect(data.trackGain, -6.5);
    final text = await File('${temp.path}/replaygain_debug.log').readAsString();
    expect(text, contains('Found ReplayGain data in Vorbis comments'));
  });
}
