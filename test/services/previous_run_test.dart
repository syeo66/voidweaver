import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:voidweaver/services/previous_run.dart';
import 'package:voidweaver_player/voidweaver_player.dart';

class _FakeHistory extends ProcessHistory {
  final Future<List<ProcessEvent>> Function() onTake;

  const _FakeHistory(this.onTake);

  @override
  Future<List<ProcessEvent>> takeNew() => onTake();
}

void main() {
  late List<LogRecord> records;
  late void Function() stopListening;

  setUp(() {
    records = [];
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    stopListening = () => subscription.cancel();
  });

  tearDown(() => stopListening());

  List<LogRecord> fromPreviousRun() =>
      records.where((r) => r.loggerName == 'previous_run').toList();

  test('logs what went wrong as a warning and the rest as info', () async {
    await logPreviousRunEnd(
      history: _FakeHistory(
        () async => const [
          ProcessEvent('The previous run crashed. boom', notable: true),
          ProcessEvent('A process ended: stopped by the user', notable: false),
        ],
      ),
    );

    final logged = fromPreviousRun();
    expect(logged.map((r) => r.message), [
      'The previous run crashed. boom',
      'A process ended: stopped by the user',
    ]);
    expect(logged.map((r) => r.level), [Level.WARNING, Level.INFO]);
  });

  test('logs nothing when there is nothing new', () async {
    await logPreviousRunEnd(history: _FakeHistory(() async => const []));

    expect(fromPreviousRun(), isEmpty);
  });

  test('does not throw where the platform has no history', () async {
    await logPreviousRunEnd(
      history: _FakeHistory(() async => throw MissingPluginException()),
    );

    expect(fromPreviousRun().single.level, Level.FINE);
  });
}
