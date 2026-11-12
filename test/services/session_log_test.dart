import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/session_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  final log = SessionLog.instance;
  File file() => File('${temp.path}/${SessionLog.fileName}');

  LogRecord record(Level level, String message, [String logger = 'test']) =>
      LogRecord(level, message, logger);

  Future<String> text() async {
    await log.flush();
    return file().readAsString();
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('session_log_test');
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Voidweaver',
      packageName: 'red.ochsenbein.voidweaver',
      version: '1.2.4',
      buildNumber: '2',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => temp.path,
        );
  });

  tearDown(() async {
    await log.resetForTest();
    await temp.delete(recursive: true);
  });

  File previous() => File('${temp.path}/${SessionLog.previousFileName}');

  test(
    'keeps the last run as the previous one, and drops the one before',
    () async {
      await previous().writeAsString('a line of the run before\n');
      await file().writeAsString('a line of the last run\n');

      await log.start();
      log.add(record(Level.INFO, 'a line of this run'));

      final content = await text();
      expect(content, isNot(contains('last run')));
      expect(content, contains('I/test: a line of this run'));
      expect(await previous().readAsString(), 'a line of the last run\n');
      expect(await log.previousSizeBytes(), greaterThan(0));
    },
  );

  test(
    'has no previous run on a first start, also with an older file left',
    () async {
      await previous().writeAsString('a stale previous run\n');

      await log.start();

      expect(await previous().exists(), isFalse);
      expect(await log.previousSizeBytes(), 0);
    },
  );

  test('writes the header first while reading the app version takes time, '
      'with the lines logged meanwhile after it, in order', () async {
    // On a device the version comes over a platform channel, late
    log.appVersion = () async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return 'Voidweaver 9.9.9 (9)';
    };

    final started = log.start();
    var n = 0;
    while (n < 50) {
      log.add(record(Level.INFO, 'line ${++n}'));
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await started;
    log.add(record(Level.INFO, 'line ${++n}'));

    final lines = (await text()).trim().split('\n');
    expect(lines.first, startsWith('=== '));
    final numbers = [
      for (final line in lines.skip(1))
        int.parse(RegExp(r'line (\d+)').firstMatch(line)!.group(1)!),
    ];
    expect(numbers, [for (var i = 1; i <= n; i++) i]);
  });

  test('starts with a header naming the app version', () async {
    await log.start();

    final first = (await text()).split('\n').first;
    expect(first, startsWith('=== Voidweaver 1.2.4 (2) on '));
    expect(first, contains('session started'));
  });

  test('keeps the lines logged before it was open, in order', () async {
    log.add(record(Level.INFO, 'early one'));
    log.add(record(Level.WARNING, 'early two'));

    await log.start();
    log.add(record(Level.INFO, 'after'));

    final lines = (await text()).split('\n');
    final one = lines.indexWhere((l) => l.contains('early one'));
    final two = lines.indexWhere((l) => l.contains('W/test: early two'));
    final after = lines.indexWhere((l) => l.contains('after'));
    expect(one, greaterThan(0), reason: 'after the header');
    expect(two, greaterThan(one));
    expect(after, greaterThan(two));
  });

  test('records FINE and up, not FINER', () async {
    await log.start();
    log.add(record(Level.FINER, 'too detailed'));
    log.add(record(Level.FINE, 'a detail'));
    log.add(record(Level.SEVERE, 'an error'));

    final content = await text();
    expect(content, isNot(contains('too detailed')));
    expect(content, contains('F/test: a detail'));
    expect(content, contains('S/test: an error'));
  });

  test('masks credentials, also in errors', () async {
    await log.start();
    log.add(
      LogRecord(
        Level.WARNING,
        'Request failed: https://music.example/rest/stream'
            '?u=alice&t=0123abcd&s=salty&id=42',
        'subsonic_api',
        Exception('GET https://music.example/rest/ping?p=hunter2 failed'),
      ),
    );

    final content = await text();
    expect(content, contains('https://music.example/rest/stream'));
    expect(content, isNot(contains('0123abcd')));
    expect(content, isNot(contains('salty')));
    expect(content, isNot(contains('hunter2')));
  });

  test('starts over with a note when it reaches its size limit', () async {
    await log.start();
    log.maxBytes = 2000;
    for (var i = 0; i < 40; i++) {
      log.add(record(Level.INFO, 'line $i'.padRight(80, '.')));
    }

    final content = await text();
    expect(await file().length(), lessThanOrEqualTo(2000));
    expect(log.sizeBytes, await file().length());
    expect(content, contains('Size limit reached'));
    expect(content, startsWith('=== Voidweaver 1.2.4 (2) on '));
    expect(content, contains('line 39'));
    expect(content, isNot(contains('line 0.')));
  });

  test('clear() empties it, and it goes on with new lines', () async {
    await log.start();
    log.add(record(Level.INFO, 'before'));
    await log.flush();

    await log.clear();
    expect(log.sizeBytes, 0);
    log.add(record(Level.INFO, 'after'));

    final content = await text();
    expect(content, isNot(contains('before')));
    expect(content, contains('after'));
    expect(log.sizeBytes, await file().length());
  });

  test('clear() removes the previous run too', () async {
    await file().writeAsString('a line of the last run\n');
    await log.start();

    await log.clear();

    expect(await previous().exists(), isFalse);
  });

  test('export() has nothing to share after a clear', () async {
    await file().writeAsString('a line of the last run\n');
    await log.start();
    await log.clear();

    expect(await log.export(), isFalse);
  });

  test(
    'removes the ReplayGain debug log it replaced, and its setting',
    () async {
      final old = File('${temp.path}/replaygain_debug.log');
      await old.writeAsString('old ReplayGain lines\n');
      SharedPreferences.setMockInitialValues({
        'replayGainDebugLoggingEnabled': true,
      });

      await log.start();

      expect(await old.exists(), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('replayGainDebugLoggingEnabled'), isFalse);
    },
  );

  test(
    'records nothing, and doesn\'t fail, when the file can\'t be opened',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => '${temp.path}/missing/dir',
          );
      log.add(record(Level.INFO, 'early'));

      await log.start();
      log.add(record(Level.INFO, 'later'));
      await log.flush();

      expect(log.sizeBytes, 0);
      expect(await log.export(), isFalse);
    },
  );
}
