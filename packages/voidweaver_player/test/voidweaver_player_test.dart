import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voidweaver_player/voidweaver_player.dart';

/// The native side of the plugin: records the calls of each player and sends
/// its events.
class _FakePlatform {
  final calls = <MethodCall>[];
  late String playerId;
  MockStreamHandlerEventSink? events;

  /// Answers calls on the player's channel; the default returns [state].
  Future<Object?> Function(MethodCall call)? onPlayerCall;
  Map<String, Object?> state = _state();

  /// Answers calls on the plugin's channel other than create/dispose (the
  /// cache methods).
  Object? Function(MethodCall call)? onPluginCall;

  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void install() {
    _messenger.setMockMethodCallHandler(
        const MethodChannel('voidweaver_player'), (call) async {
      calls.add(call);
      if (call.method == 'create') {
        playerId = (call.arguments as Map)['id'] as String;
        _messenger.setMockMethodCallHandler(
            MethodChannel('voidweaver_player/$playerId'), (call) async {
          calls.add(call);
          return onPlayerCall != null ? onPlayerCall!(call) : state;
        });
        _messenger.setMockStreamHandler(
            EventChannel('voidweaver_player/$playerId/events'),
            MockStreamHandler.inline(
                onListen: (_, sink) => events = sink,
                onCancel: (_) => events = null));
        return null;
      }
      if (call.method == 'dispose') return null;
      return onPluginCall?.call(call);
    });
  }

  List<String> get methods => [for (final call in calls) call.method];

  MethodCall lastCall(String method) =>
      calls.lastWhere((call) => call.method == method);
}

Map<String, Object?> _state(
        {bool playing = false,
        int processingState = 0,
        int? index,
        int position = 0,
        int? duration}) =>
    {
      'playing': playing,
      'processingState': processingState,
      'index': index,
      'position': position,
      'duration': duration,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlatform platform;
  late VoidweaverPlayer player;

  setUp(() {
    platform = _FakePlatform()..install();
    player = VoidweaverPlayer();
  });

  tearDown(() => player.dispose());

  AudioSource source(String name, {double gain = 1.0}) =>
      AudioSource.uri(Uri.parse('https://music.example.com/$name'),
          tag: name,
          gain: gain,
          cacheKey: 'server|$name',
          title: 'Title $name',
          artist: 'Artist',
          album: 'Album',
          artUri: Uri.parse('https://music.example.com/art/$name'));

  group('setAudioSources', () {
    test('hands the items with their gain, cache key and metadata over',
        () async {
      final a = source('a', gain: 0.5);
      final b = source('b');

      await player.setAudioSources([a, b],
          initialIndex: 1, initialPosition: const Duration(seconds: 30));

      final arguments = platform.lastCall('setAudioSources').arguments
          as Map<Object?, Object?>;
      expect(arguments['initialIndex'], 1);
      expect(arguments['initialPosition'], 30000);
      expect(arguments['sources'], [
        {
          'id': a.id,
          'uri': 'https://music.example.com/a',
          'gain': 0.5,
          'cacheKey': 'server|a',
          'title': 'Title a',
          'artist': 'Artist',
          'album': 'Album',
          'artUri': 'https://music.example.com/art/a',
        },
        containsPair('id', b.id),
      ]);
      expect(player.sequence, [a, b]);
      expect(player.gainOf(a), 0.5);
    });

    test('applies the state it returns', () async {
      platform.state = _state(
          processingState: ProcessingState.ready.index,
          index: 1,
          position: 30000,
          duration: 180000);
      final indexes = <int?>[];
      player.currentIndexStream.listen(indexes.add);

      final duration = await player.setAudioSources([source('a'), source('b')]);

      await pumpEventQueue();

      expect(duration, const Duration(minutes: 3));
      expect(player.currentIndex, 1);
      expect(player.position, const Duration(seconds: 30));
      expect(player.processingState, ProcessingState.ready);
      expect(indexes, [1]);
    });

    test('throws a PlayerException with the failed item', () async {
      platform.onPlayerCall = (_) async => throw PlatformException(
          code: 'error',
          message: 'Source error',
          details: {'code': 2001, 'message': 'Source error', 'index': 1});

      await expectLater(
          player.setAudioSources([source('a'), source('b')]),
          throwsA(isA<PlayerException>()
              .having((e) => e.code, 'code', 2001)
              .having((e) => e.index, 'index', 1)));
    });

    test('throws a PlayerInterruptedException when replaced', () async {
      platform.onPlayerCall =
          (_) async => throw PlatformException(code: 'interrupted');

      await expectLater(player.setAudioSources([source('a')]),
          throwsA(isA<PlayerInterruptedException>()));
    });
  });

  group('events', () {
    Future<void> connect() async {
      await player.play();
      expect(platform.events, isNotNull);
    }

    test('state events update the streams, each only on a change', () async {
      await connect();
      final states = <PlayerState>[];
      final positions = <Duration>[];
      player.playerStateStream.listen(states.add);
      player.positionStream.listen(positions.add);

      final playing = _state(
          playing: true,
          processingState: ProcessingState.ready.index,
          index: 0,
          position: 200);
      platform.events!.success(playing);
      platform.events!.success(playing);
      platform.events!.success({...playing, 'position': 400});
      await pumpEventQueue();

      expect(states, [const PlayerState(true, ProcessingState.ready)]);
      expect(positions, [
        const Duration(milliseconds: 200),
        const Duration(milliseconds: 400)
      ]);
      expect(player.playing, isTrue);
    });

    test('error events go to the error stream', () async {
      await connect();
      final errors = player.errorStream.first;

      platform.events!.success(
          {'type': 'error', 'code': 2001, 'message': 'offline', 'index': 2});

      final error = await errors;
      expect(error.code, 2001);
      expect(error.message, 'offline');
      expect(error.index, 2);
    });

    test('system commands go to the command stream', () async {
      await connect();
      final commands = <SystemCommand>[];
      player.commandStream.listen(commands.add);

      platform.events!.success({'type': 'command', 'command': 'next'});
      platform.events!
          .success({'type': 'command', 'command': 'seek', 'position': 42000});
      await pumpEventQueue();

      expect(commands.map((c) => c.type),
          [SystemCommandType.next, SystemCommandType.seek]);
      expect(commands.first.position, isNull);
      expect(commands.last.position, const Duration(seconds: 42));
    });

    test('are ignored after dispose', () async {
      await connect();
      final sink = platform.events!;
      await player.dispose();

      expect(platform.methods, contains('dispose'));
      expect(() => sink.success(_state(playing: true)), returnsNormally);
      expect(player.playing, isFalse);
    });
  });

  test('setGain sends only changed gains', () async {
    final a = source('a', gain: 0.5);
    await player.setAudioSources([a]);

    await player.setGain(a, 0.5);
    await player.setGain(a, 0.8);

    expect(platform.methods.where((m) => m == 'setGain'), hasLength(1));
    expect(platform.lastCall('setGain').arguments, {'id': a.id, 'gain': 0.8});
    expect(player.gainOf(a), 0.8);
  });

  test('seek sends the position and the target item', () async {
    await player.seek(const Duration(seconds: 5), index: 2);
    await player.seek(null);

    final seeks = [
      for (final call in platform.calls)
        if (call.method == 'seek') call.arguments
    ];
    expect(seeks, [
      {'position': 5000, 'index': 2},
      {'position': 0, 'index': null},
    ]);
  });

  group('MediaCache', () {
    const cache = MediaCache();

    test('passes the key and URL to prefetch', () async {
      await cache.prefetch(
          'server|a', Uri.parse('https://music.example.com/a'));

      expect(platform.lastCall('cache.prefetch').arguments,
          {'key': 'server|a', 'uri': 'https://music.example.com/a'});
    });

    test('reports the cached keys, none if the platform returns null',
        () async {
      platform.onPluginCall = (call) => ['server|b'];
      expect(await cache.cachedKeys(['server|a', 'server|b']), ['server|b']);

      platform.onPluginCall = (call) => null;
      expect(await cache.cachedKeys(['server|a']), isEmpty);
      expect(await cache.sizeInBytes(), 0);
    });

    test('returns the head of a cached item', () async {
      platform.onPluginCall = (call) => Uint8List.fromList([1, 2, 3]);

      expect(await cache.readHead('server|a', 3), [1, 2, 3]);
      expect(platform.lastCall('cache.readHead').arguments,
          {'key': 'server|a', 'length': 3});
    });
  });
}
