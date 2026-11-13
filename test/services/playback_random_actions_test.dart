// Random sequences of user actions and player events against
// AudioPlayerService, checking rules that must hold once everything has
// settled. The playback bugs fixed so far came from orders of events nobody
// wrote a test for (a Pause during a skip whose target a second press had
// moved, a pause while buffering, ...); this tries many orders.
//
// Every run is deterministic: seeded, with a fake clock for the service, and
// the event loop only advanced by pumpEventQueue(). Not fakeAsync: awaiting
// StreamSubscription.cancel() continues on the root zone's microtask queue,
// which fakeAsync doesn't run, so _seekToItem() looked stuck.
//
// A track only ends a second (of fake time) or more after the player last
// seeked or loaded, see _canEnd: the fake would otherwise end a track the
// moment it was restarted. That also leaves out a track ending right after
// a seek near its end, which the rules below therefore don't cover.
//
// Besides the controls and player events, a run can start with a restored
// queue (restorePlaybackState(), which the first actions overlap), start an
// album or a single song, and change the password: the stream URLs of the
// player's items then carry an outdated one, and fail unless cached.
//
// A failure prints its seed and the actions. Replay one, with the service's
// log lines between the actions:
//   flutter test test/services/playback_random_actions_test.dart \
//     --dart-define=PLAYBACK_SEED=<seed>
// More runs: --dart-define=PLAYBACK_RUNS=<n> (prints how often each rule
// was checked); longer ones: --dart-define=PLAYBACK_STEPS=<n> (default 40),
// which a replay needs too; other seeds: --dart-define=PLAYBACK_FIRST_SEED=<n>
// (default 0), as the nightly workflow does.

import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidweaver/services/audio_player_service.dart';
import 'package:voidweaver/services/playback_persistence.dart';
import 'package:voidweaver/services/replaygain_reader.dart';
import 'package:voidweaver/services/scrobble_queue.dart';
import 'package:voidweaver/services/settings_service.dart';
import 'package:voidweaver/services/subsonic_api.dart';
import 'package:voidweaver_player/voidweaver_player.dart';

import '../test_helpers/fake_audio_cache.dart';
import '../test_helpers/mock_api.dart';
import '../test_helpers/mock_audio_player.dart';
import '../test_helpers/mocks.mocks.dart';

const _seedOverride = int.fromEnvironment('PLAYBACK_SEED', defaultValue: -1);
const _runsOverride = int.fromEnvironment('PLAYBACK_RUNS', defaultValue: -1);
// The runs use the seeds from this one on. Every CI run of the test checks
// the same seeds; the nightly workflow tries new ones.
const _firstSeed = int.fromEnvironment('PLAYBACK_FIRST_SEED');
// About 4 s; more with PLAYBACK_RUNS
const _defaultRuns = 1000;
const _defaultSteps = 40;
const _steps = int.fromEnvironment(
  'PLAYBACK_STEPS',
  defaultValue: _defaultSteps,
);

/// The service's skip debounce and Previous's restart threshold
const _skipDebounceMs = 100;
const _restartThreshold = Duration(seconds: 3);

/// What the user last asked for, as far as it decides whether the player
/// must be playing in the end. Unknown when the model can't tell (a skip
/// press the debounce may have dropped).
enum _Intent { unknown, play, pause }

/// The stream URL of the song [id], made while [password] was current (the
/// `p` parameter stands in for the token and salt)
String _urlFor(String id, int password) =>
    'https://music.test/rest/stream?id=$id&p=$password';

/// The song id, and the password, of a URL made by [_urlFor]
String _idOf(String url) => Uri.parse(url).queryParameters['id']!;
int _passwordOf(String url) => int.parse(Uri.parse(url).queryParameters['p']!);

final _titleInError = RegExp(r'"Title ([^"]+)"');

Song _song(String id) => Song(
  id: id,
  title: 'Title $id',
  artist: 'Artist',
  album: 'Album',
  duration: 180,
  // Set, so the service doesn't read ReplayGain from the (fake) stream
  replayGainTrackGain: -6.0,
);

/// How often the rules about the last press were checked, over all runs
class _Stats {
  int runs = 0;
  int pauseChecked = 0;
  int playChecked = 0;
  int failureChecked = 0;
  // Of the failure rule's checks, those of a queue the playlist replaced
  int replacedFailureChecked = 0;
  int restores = 0;
  int quietRestoreFailures = 0;
  int passwordChanges = 0;
  int songStarts = 0;
  // The network coming back, and the times it resumed a track the network
  // had failed on
  int networkEvents = 0;
  int networkResumes = 0;
  // Loads of an item that failed only because its URL carries an outdated
  // password
  int staleFailures = 0;
}

/// Holds the saved queue in memory, and hands it to [loadPlaybackState]
/// once [loaded] completes (a slow read at startup). Saves are dropped.
class _FakePersistence implements PlaybackPersistenceService {
  _FakePersistence(this.saved);

  final PersistedPlaybackState? saved;
  final loaded = Completer<void>();

  @override
  Future<void> initialize() async {}

  @override
  Future<PersistedPlaybackState?> loadPlaybackState() async {
    await loaded.future;
    return saved;
  }

  @override
  Future<void> savePlaybackState(PersistedPlaybackState state) async {}

  @override
  void queueChanged() {}

  @override
  void schedulePositionSave(PersistedPlaybackState state) {}

  @override
  Future<void> clearPlaybackState() async {}

  @override
  void flushPendingPositionSave() {}

  @override
  void dispose() {}
}

/// Hands what the service queues to [onNowPlaying] and [onSubmission], when
/// it's queued, and sends nothing
class _RecordingScrobbleQueue extends ScrobbleQueue {
  _RecordingScrobbleQueue(
    super.api, {
    required this.onNowPlaying,
    required this.onSubmission,
  });

  final void Function(String songId) onNowPlaying;
  final void Function(String songId) onSubmission;

  @override
  Future<void> queueNowPlaying(String songId) async => onNowPlaying(songId);

  @override
  Future<void> queueSubmission(String songId, {DateTime? playedAt}) async =>
      onSubmission(songId);
}

/// One run: [_steps] random actions, then the checks.
class _Run {
  _Run(this.seed) : random = Random(seed);

  final int seed;
  final Random random;

  /// The actions, and with a replayed seed the service's log lines
  final log = <String>[];
  final problems = <String>[];

  var now = DateTime(2026);
  late final FakeAudioCache cache;
  late final MockAudioPlayer player;
  late final AudioPlayerService service;

  var intent = _Intent.unknown;
  // Whether something since the last press can keep a Play from ending up
  // playing: a track of the queue that can't load, a load error, a start
  // that failed
  var disturbed = false;
  // The last time a skip press was surely let through by the debounce, and
  // the last time one may have been; the service's _lastSkipTime is between
  DateTime? lastSkipSure;
  DateTime? lastSkipPossible;
  var albums = 0;
  // When the player last seeked or loaded, as far as the steps have seen
  // (see _noteSeeks()): a track doesn't end right after that
  var lastSeekAt = DateTime(2026);
  var seenSeeks = 0;

  // The current password: URLs made with an earlier one fail, unless their
  // song is cached
  var password = 0;
  // Songs (by id) whose URLs fail to load, as with the network down for them
  final failingSongs = <String>{};
  // Songs that had a reason to fail: in failingSongs at some point, or a
  // load error while the player was on them. A failure reported for any
  // other song came from the outdated password alone, which the service
  // handles by loading the queue again with new URLs. Only grows (a song
  // stays in it after its network comes back): deliberately conservative,
  // so the rule never flags a report that has another explanation.
  final broken = <String>{};

  // The restore at the start of the run, if any: in progress, whether Play
  // was pressed while it was (with a queue to play), and the failure it
  // kept quiet (the player's failure count then)
  _FakePersistence? persistence;
  var restoring = false;
  var playDuringRestore = false;
  int? quietFailure;
  // The step before which the saved queue has been read
  var restoreReadAt = 0;

  // Every song the player made current, by id
  final started = <String>{};

  // Plays of each song (by id) so far: each time it became the player's
  // current item or was put back at its start, and the submissions the
  // service queued for it. A song can't be scrobbled more often than played.
  final plays = <String, int>{};
  final submissions = <String, int>{};
  // The song the service rewound after the end of the queue: Play replays it
  // as a new play, the rewind itself isn't one
  String? rewound;

  // Errors reported (playbackErrors, and starts that threw), and how many
  // there were when the player last failed to load an item
  var reports = 0;
  var reportsAtFailure = 0;
  var seenFailures = 0;

  /// Returns the problems found (empty if none) followed by the actions.
  Future<List<String>> run(_Stats stats) async {
    final StreamSubscription<LogRecord>? logRecords = _seedOverride >= 0
        ? (Logger.root..level = Level.ALL).onRecord.listen((r) {
            if (r.loggerName == 'audio_player') log.add('    ${r.message}');
          })
        : null;
    await runZonedGuarded(
      () async {
        try {
          await _run(stats);
        } catch (e, stack) {
          problems.add('the run threw $e\n$stack');
        }
      },
      (error, stack) {
        problems.add('uncaught error: $error\n$stack');
      },
    );
    unawaited(logRecords?.cancel());
    return problems.isEmpty
        ? const []
        : [
            // What a replay needs, see the top of the file
            _steps == _defaultSteps
                ? 'seed $seed:'
                : 'seed $seed (PLAYBACK_STEPS=$_steps):',
            ...problems,
            '',
            'actions:',
            ...log,
          ];
  }

  late final _Stats stats;

  Future<void> _run(_Stats stats) async {
    this.stats = stats;
    SharedPreferences.setMockInitialValues({});
    final api = newMockApi();
    when(api.getStreamUrl(any)).thenAnswer(
      (invocation) =>
          _urlFor(invocation.positionalArguments.first as String, password),
    );
    when(api.readReplayGain(any))
        .thenAnswer((_) async => const ReplayGainData());
    when(api.scrobbleNowPlaying(any)).thenAnswer((_) async {});
    when(api.scrobbleSubmission(any, playedAt: anyNamed('playedAt')))
        .thenAnswer((_) async {});

    final settings = MockSettingsService();
    when(settings.replayGainMode).thenReturn(ReplayGainMode.off);
    when(settings.replayGainPreamp).thenReturn(0.0);
    when(settings.replayGainFallbackGain).thenReturn(0.0);
    when(settings.replayGainPreventClipping).thenReturn(true);
    when(settings.scrobbleMinPlayTimeMinutes).thenReturn(4.0);
    when(settings.scrobbleThresholdPercent).thenReturn(50.0);
    when(
      settings.calculateVolumeAdjustment(
        trackGain: anyNamed('trackGain'),
        albumGain: anyNamed('albumGain'),
        trackPeak: anyNamed('trackPeak'),
        albumPeak: anyNamed('albumPeak'),
        fromAlbum: anyNamed('fromAlbum'),
      ),
    ).thenReturn(1.0);

    cache = FakeAudioCache()..reachable = random.nextBool();
    player = MockAudioPlayer(isCached: cache.isCachedKey)
      ..failsUrl = (url) {
        final song = _idOf(url);
        if (failingSongs.contains(song)) return true;
        if (_passwordOf(url) == password) return false;
        if (!cache.cached.contains(song)) stats.staleFailures++;
        return true;
      };
    // Half the runs fail for the network (Media3's
    // ERROR_CODE_IO_NETWORK_CONNECTION_FAILED), which the network coming back
    // resumes; the other half for no particular cause, which it doesn't.
    // From the seed, so the random actions stay the same.
    player.errorCode = seed.isOdd ? 2001 : 0;
    player.onSeekWithinItem = (position) {
      final song = _currentItemSong;
      if (position != Duration.zero || song == null) return;
      if (rewound == null) _countPlay(song);
    };

    // Before the service subscribes, so these listeners see each event
    // first: a system command is taken into the model just before the
    // service acts on it, not when it was sent
    final commands = player.commandStream.listen(_onCommand);
    final indexes = player.currentIndexStream.listen((index) {
      if (index != null && index < player.sequence.length) {
        final song = _idOf('${player.sequence[index].uri}');
        started.add(song);
        rewound = null;
        // The item the event reports: the player may have moved on since
        _countPlay(song);
      }
    });
    final states = player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed && state.playing) {
        _onQueueEnd();
      }
    });

    // Before the service: its draws come first for every seed
    if (random.nextInt(3) == 0) _prepareRestore(stats);

    service = AudioPlayerService(
      api,
      settings,
      audioPlayer: player,
      audioCache: cache,
      persistence: persistence,
      clock: () => now,
      scrobbleQueue: _RecordingScrobbleQueue(
        api,
        onNowPlaying: _onNowPlaying,
        onSubmission: _onSubmission,
      ),
      // Not retried within a run
      downloadRetryDelay: const Duration(hours: 1),
    );
    final errors = service.playbackErrors.listen(_onPlaybackError);

    if (persistence != null) _startRestore();
    for (var i = 0; i < _steps; i++) {
      if (i == restoreReadAt) _readSavedQueue();
      await _step();
    }

    // Settle: the saved queue is read, slow seeks and loads finish,
    // buffering ends
    log.add('-- settle --');
    _readSavedQueue();
    player.seekGate?.complete();
    player.seekGate = null;
    player.loadGate?.complete();
    player.loadGate = null;
    now = now.add(const Duration(seconds: 2));
    await pumpEventQueue(times: 200);
    if (player.processingState == ProcessingState.buffering) {
      player.simulateBufferingEnd();
    }
    await pumpEventQueue(times: 200);
    if ((seed ~/ 2).isOdd) {
      // In half the runs, once more after everything settled: a failure the
      // network caused is resumed, and the rules check where that ends
      _networkAvailable();
      await pumpEventQueue(times: 200);
      if (player.processingState == ProcessingState.buffering) {
        player.simulateBufferingEnd();
      }
      await pumpEventQueue(times: 200);
    }

    _check(stats);

    await errors.cancel();
    await commands.cancel();
    await indexes.cancel();
    await states.cancel();
    service.dispose();
    await player.dispose();
    await pumpEventQueue();
  }

  // Plays and scrobbles

  /// The id of the song of the player's current item
  String? get _currentItemSong {
    final index = player.currentIndex;
    if (index == null || index >= player.sequence.length) return null;
    return Uri.parse('${player.sequence[index].uri}').queryParameters['id'];
  }

  void _countPlay(String song) => plays[song] = (plays[song] ?? 0) + 1;

  void _onNowPlaying(String song) {
    log.add('  -> now playing $song');
    if (song != _currentItemSong) {
      problems.add(
        '"now playing" for $song while the player is on $_currentItemSong',
      );
    }
  }

  // The restore

  /// Saves a queue for the restore at the start of the run: some of its
  /// songs fail to load, some are cached.
  void _prepareRestore(_Stats stats) {
    stats.restores++;
    final count = 1 + random.nextInt(5);
    final songs = [for (var i = 0; i < count; i++) _song('r-s$i')];
    final index = random.nextInt(count);
    final position = Duration(seconds: random.nextInt(170));
    for (final song in songs) {
      switch (random.nextInt(4)) {
        case 0:
          failingSongs.add(song.id);
          broken.add(song.id);
        case 1:
          cache.cached.add(song.id);
      }
    }
    restoreReadAt = random.nextInt(4);
    persistence = _FakePersistence(
      PersistedPlaybackState(
        playlist: songs,
        currentIndex: index,
        currentPosition: position,
        isPlaying: random.nextBool(),
        lastUpdated: now,
        playlistSource: random.nextBool() ? 'album' : 'random',
        sourceId: 'r',
      ),
    );
    log.add(
      'saved queue: $count songs, index $index at $position; '
      'failing $failingSongs, cached ${cache.cached}; '
      'read before step $restoreReadAt',
    );
  }

  /// Restores the saved queue, as at startup, without waiting for it: the
  /// first actions overlap it.
  void _startRestore() {
    log.add('restorePlaybackState');
    restoring = true;
    // A restored queue waits for Play
    intent = _Intent.pause;
    unawaited(
      service.restorePlaybackState().then(
        _onRestored,
        onError: (Object e) {
          problems.add('restorePlaybackState threw $e');
        },
      ),
    );
  }

  void _readSavedQueue() {
    final loaded = persistence?.loaded;
    if (loaded == null || loaded.isCompleted) return;
    log.add('(the saved queue has been read)');
    loaded.complete();
  }

  // A load error the steps caused while the restore ran, which the model
  // can't tell from the restore's own failure
  var errorDuringRestore = false;

  /// The restore is done. If it ended on a track that failed, without Play
  /// pressed while it ran, the failure stays quiet: no report, the queue
  /// shows paused, and play() loads it again (see restorePlaybackState()).
  void _onRestored(bool restored) {
    restoring = false;
    log.add('  -> restorePlaybackState: $restored');
    if (restored &&
        !playDuringRestore &&
        !errorDuringRestore &&
        player.processingState == ProcessingState.idle &&
        player.idleCause == 'error') {
      _noteFailures();
      quietFailure = player.failures;
      stats.quietRestoreFailures++;
    }
  }

  void _onSubmission(String song) {
    final count = submissions[song] = (submissions[song] ?? 0) + 1;
    log.add('  -> scrobbled $song');
    if (count > (plays[song] ?? 0)) {
      problems.add(
        '$song scrobbled $count times, played ${plays[song] ?? 0} times',
      );
    }
  }

  /// Notes a failure of the player to load an item since the last call
  void _noteFailures() {
    if (player.failures != seenFailures) {
      seenFailures = player.failures;
      reportsAtFailure = reports;
    }
  }

  void _report() {
    // Its failure came first
    _noteFailures();
    reports++;
  }

  // The model of what the presses ask for

  void _setIntent(_Intent value, {List<Song>? queue}) {
    intent = value;
    disturbed = _hasFailingTrack(queue ?? service.playlist);
  }

  /// Whether [songs] has one that can't be played. Not a song whose item
  /// only carries an outdated password: the service loads the queue again
  /// with new URLs for that.
  bool _hasFailingTrack(List<Song> songs) => songs.any(
    (song) => failingSongs.contains(song.id) && !cache.cached.contains(song.id),
  );

  /// Whether a skip press now gets through the debounce, or null if the
  /// model can't tell
  bool? _passesDebounce() {
    bool within(DateTime? time) =>
        time != null && now.difference(time).inMilliseconds <= _skipDebounceMs;
    if (within(lastSkipSure)) return false;
    if (!within(lastSkipPossible)) return true;
    return null;
  }

  /// A Next or Previous, as the service takes it (see _skip()): the range
  /// first, then the debounce, then a skip in progress takes the press as a
  /// new target, otherwise it's a new skip, which plays.
  void _onSkip({required bool next}) {
    if (service.isSkipOperationInProgress) {
      // Moves the target, if it's in range (the model doesn't know the
      // target). Plays unless a pause during the skip holds: the intent
      // stays as it is.
      if (_passesDebounce() != false) {
        lastSkipPossible = now;
        rewound = null;
      }
      return;
    }
    final index = service.currentIndex;
    final int target;
    if (next) {
      target = index + 1;
    } else {
      target = service.currentPosition > _restartThreshold
          ? index
          : max(index - 1, 0);
    }
    if (target >= service.playlist.length) return;
    final passes = _passesDebounce();
    // A skip that may get through moves off the rewound song, or restarts
    // it, which is a play of its own (counted with its seek to 0:00)
    if (passes != false) rewound = null;
    switch (passes) {
      case false:
        return;
      case true:
        lastSkipSure = lastSkipPossible = now;
        _setIntent(_Intent.play);
      case null:
        lastSkipPossible = now;
        intent = _Intent.unknown;
    }
  }

  void _onPress(SystemCommandType type) {
    switch (type) {
      case SystemCommandType.play:
        // Does nothing without a queue (e.g. a restore still reading it)
        if (service.playlist.isEmpty) break;
        if (restoring) playDuringRestore = true;
        _setIntent(_Intent.play);
        // Replays a song rewound after the end of the queue
        final song = rewound;
        if (song != null && service.playlist.isNotEmpty) {
          rewound = null;
          _countPlay(song);
        }
      case SystemCommandType.pause:
      case SystemCommandType.stop:
        intent = _Intent.pause;
      case SystemCommandType.next:
        _onSkip(next: true);
      case SystemCommandType.previous:
        _onSkip(next: false);
      case SystemCommandType.seek:
        break;
    }
  }

  /// The player reports the end of the queue. The service pauses at the
  /// start of the last track if nothing is changing the player and it's on
  /// the service's current track (see PlayerWorker.playerCompleted());
  /// otherwise it looks again after the change, and the model can't tell.
  void _onQueueEnd() {
    final onCurrentTrack =
        _holdsPlaylist(service.playlist) &&
        player.currentIndex == service.currentIndex;
    if (service.pendingPlayerOps == 0 && onCurrentTrack) {
      log.add('  (the queue ended: the service pauses)');
      intent = _Intent.pause;
      rewound = service.currentSong?.id;
    } else if (intent == _Intent.play) {
      intent = _Intent.unknown;
    }
  }

  void _onCommand(SystemCommand command) {
    log.add('  (system ${command.type.name} arrives)');
    _onPress(command.type);
  }

  void _onPlaybackError(String message) {
    log.add('  -> playbackErrors: $message');
    _report();
    disturbed = true;
    final id = _titleInError.firstMatch(message)?.group(1);
    if (id == null) {
      problems.add('an error names no track: $message');
    } else if (!started.contains(id)) {
      problems.add('an error names a track that never started: $message');
    } else if (!broken.contains(id)) {
      problems.add(
        'an error for $id, which only had an outdated password: $message',
      );
    }
  }

  /// Whether the player's sequence is made from [songs], with whatever
  /// password
  bool _holdsPlaylist(List<Song> songs) => _listEquals(
    [for (final url in player.sequenceSources) _idOf(url)],
    [for (final song in songs) song.id],
  );

  // The actions

  /// Runs [action] without waiting for it, like a press. Only a start may
  /// fail; it throws for the caller to show.
  void _press(
    String name,
    Future<void> Function() action, {
    bool mayFail = false,
  }) {
    log.add(name);
    unawaited(
      action().catchError((Object e) {
        log.add('  -> $name threw: $e');
        if (mayFail) {
          _report();
          disturbed = true;
        } else {
          problems.add('$name threw $e');
        }
      }),
    );
  }

  /// A press of [type], in the app or as a system command
  void _control(SystemCommandType type, [Duration? position]) {
    if (random.nextInt(3) == 0) {
      log.add('system: ${type.name}${position == null ? '' : '($position)'}');
      player.simulateSystemCommand(type, position);
      return;
    }
    // Synchronously before the service acts on it, see _onCommand()
    _onPress(type);
    switch (type) {
      case SystemCommandType.play:
        _press('play', service.play);
      case SystemCommandType.pause:
        _press('pause', service.pause);
      case SystemCommandType.stop:
        _press('stop', service.stop);
      case SystemCommandType.next:
        _press('next', service.next);
      case SystemCommandType.previous:
        _press('previous', service.previous);
      case SystemCommandType.seek:
        _press('seekTo($position)', () => service.seekTo(position!));
    }
  }

  /// Notes a seek or load the player made since the last call.
  void _noteSeeks() {
    final seeks = player.seeks.length + player.loadedSources.length;
    if (seeks != seenSeeks) {
      seenSeeks = seeks;
      lastSeekAt = now;
    }
  }

  /// Whether the current track can end now: not within a second after a
  /// seek or load, which put the player back at a position it plays on from,
  /// or after one that was waiting finished.
  /// (Only the fake player could end a track the moment it was restarted,
  /// before the service has finished the restart.)
  bool get _canEnd => now.difference(lastSeekAt) >= const Duration(seconds: 1);

  bool get _ready =>
      player.sequence.isNotEmpty &&
      player.currentIndex != null &&
      player.processingState == ProcessingState.ready;

  Future<void> _step() async {
    _noteSeeks();
    final roll = random.nextInt(100);
    if (roll < 12) {
      _control(SystemCommandType.play);
    } else if (roll < 24) {
      _control(SystemCommandType.pause);
    } else if (roll < 28) {
      _control(SystemCommandType.stop);
    } else if (roll < 40) {
      _control(SystemCommandType.next);
    } else if (roll < 48) {
      _control(SystemCommandType.previous);
    } else if (roll < 53) {
      _control(SystemCommandType.seek, Duration(seconds: random.nextInt(180)));
    } else if (roll < 60) {
      final count = 1 + random.nextInt(5);
      final id = 'a${++albums}';
      final album = Album(
        id: id,
        name: 'Album $id',
        artist: 'Artist',
        songs: [for (var i = 0; i < count; i++) _song('$id-s$i')],
      );
      _setIntent(_Intent.play, queue: album.songs);
      _press(
        'playAlbum($id, $count songs)',
        () => service.playAlbum(album),
        mayFail: true,
      );
    } else if (roll < 68) {
      if (_ready && player.playing && _canEnd) {
        final last = player.currentIndex! + 1 >= player.sequence.length;
        log.add(last ? 'player: queue ends' : 'player: track ends');
        player.simulateCompletion();
      }
    } else if (roll < 71) {
      if (_ready && player.playing) {
        log.add('player: buffering');
        player.simulateBuffering();
      }
    } else if (roll < 74) {
      if (player.processingState == ProcessingState.buffering) {
        log.add('player: buffering ends');
        player.simulateBufferingEnd();
        // A seek or load waiting for it is done: the item plays from here
        lastSeekAt = now;
      }
    } else if (roll < 76) {
      if (player.sequence.isNotEmpty &&
          player.processingState != ProcessingState.idle) {
        log.add('player: load error');
        disturbed = true;
        broken.add(_currentItemSong!);
        if (restoring) errorDuringRestore = true;
        player.simulateLoadError();
      }
    } else if (roll < 78) {
      if (player.playing) {
        log.add('player: audio focus lost');
        if (intent == _Intent.play) intent = _Intent.unknown;
        player.simulateFocusLoss();
      }
    } else if (roll < 81) {
      if (player.sequence.isNotEmpty) {
        final i = random.nextInt(player.sequence.length);
        final song = _idOf('${player.sequence[i].uri}');
        if (failingSongs.remove(song)) {
          log.add('network: $song loads again');
        } else {
          log.add('network: $song fails');
          failingSongs.add(song);
          broken.add(song);
          if (_hasFailingTrack(service.playlist)) disturbed = true;
        }
      }
    } else if (roll < 86) {
      if (player.seekGate == null) {
        log.add('player: seeks are slow');
        player.seekGate = Completer();
      } else {
        log.add('player: slow seeks finish');
        player.seekGate!.complete();
        player.seekGate = null;
        lastSeekAt = now;
      }
    } else if (roll < 90) {
      if (player.loadGate == null) {
        log.add('player: loads are slow');
        player.loadGate = Completer();
      } else {
        log.add('player: slow loads finish');
        player.loadGate!.complete();
        player.loadGate = null;
        lastSeekAt = now;
      }
    } else if (roll < 93) {
      // Changed on the server and entered in the app: the URLs of the
      // player's items carry the old one from now on
      password++;
      stats.passwordChanges++;
      log.add('password changed (to $password)');
      service.credentialsChanged();
    } else if (roll < 96) {
      final id = 's${++albums}';
      final song = _song(id);
      stats.songStarts++;
      _setIntent(_Intent.play, queue: [song]);
      _press('playSong($id)', () => service.playSong(song), mayFail: true);
    } else if (roll < 98) {
      _networkAvailable();
    }

    // Time between this and the next action: none (the actions overlap),
    // one microtask, a few turns of the event loop, or long enough for the
    // skip debounce to pass
    switch (random.nextInt(4)) {
      case 0:
        break;
      case 1:
        await Future<void>.value();
      case 2:
        now = now.add(Duration(milliseconds: random.nextInt(60)));
        await pumpEventQueue(times: 1 + random.nextInt(5));
      default:
        now = now.add(Duration(milliseconds: 100 + random.nextInt(400)));
        await pumpEventQueue();
    }
  }

  /// The network coming back. It resumes a track the network failed on
  /// while it was meant to play, unless anything was pressed since: like a
  /// Play, which the rules hold to (the Pause/Stop rule in particular).
  void _networkAvailable() {
    stats.networkEvents++;
    final wanted = service.playWhenReady;
    log.add('network: available');
    cache.simulateNetworkAvailable();
    if (!wanted && service.playWhenReady) {
      stats.networkResumes++;
      log.add('    resumes');
    }
  }

  // The rules that hold once nothing is in progress any more

  void _check(_Stats stats) {
    final state =
        'service: ${service.playbackState}, index ${service.currentIndex}, '
        'playWhenReady ${service.playWhenReady}; '
        'player: playing ${player.playing}, ${player.processingState}, '
        'index ${player.currentIndex}';
    void problem(String description) => problems.add('$description ($state)');

    if (service.isSkipOperationInProgress) {
      problem('a skip is still in progress');
    }
    if (service.startsInProgress != 0) {
      problem('${service.startsInProgress} starts still in progress');
    }
    if (service.playbackState == PlaybackState.loading) {
      problem('stuck at loading');
    }

    final playlist = service.playlist;
    if (playlist.isNotEmpty) {
      if (service.currentSong?.id != playlist[service.currentIndex].id) {
        problem(
          'currentSong ${service.currentSong?.id} isn\'t the playlist\'s '
          'song at ${service.currentIndex}',
        );
      }
      if (player.processingState != ProcessingState.idle) {
        if (!_holdsPlaylist(playlist)) {
          problem(
            'the player holds ${player.sequenceSources}, not the playlist',
          );
        } else if (player.currentIndex != service.currentIndex) {
          problem('service and player are on different tracks');
        }
      }
    }

    // A player that has loaded its track isn't marked for loading the queue
    // again: Play would load it once more, from the start
    if (player.processingState == ProcessingState.ready &&
        service.needsSourceReload) {
      problem('ready, but marked for loading the queue again');
    }

    switch (player.processingState) {
      case ProcessingState.ready:
        final expected = player.playing
            ? PlaybackState.playing
            : PlaybackState.paused;
        if (service.playbackState != expected) {
          problem('state should be $expected');
        }
      case ProcessingState.completed:
        if (player.playing) problem('the queue completed but stays playing');
      default:
        break;
    }

    // A failure nothing superseded: playback stopped on it, and it was
    // reported once. Unless the restore failed quietly: then it shows
    // paused, waiting for Play, and nothing was reported. A failure of a
    // queue the playlist replaced (stop() ended the new one's load before it
    // reached the player) is the service's to ignore: it isn't playing or
    // loading, and play() loads the playlist.
    _noteFailures();
    if (player.processingState == ProcessingState.idle &&
        player.idleCause == 'error' &&
        _holdsPlaylist(playlist)) {
      stats.failureChecked++;
      final quiet = quietFailure == player.failures;
      final state = quiet ? PlaybackState.paused : PlaybackState.stopped;
      if (service.playbackState != state) {
        problem(
          '${quiet ? 'the restore\'s quiet failure' : 'a failure'} left '
          'the state at ${service.playbackState}',
        );
      }
      final count = reports - reportsAtFailure;
      if (count != (quiet ? 0 : 1)) {
        problem(
          '${quiet ? 'the restore\'s quiet failure' : 'the last failure'} '
          'was reported $count times',
        );
      }
    } else if (player.processingState == ProcessingState.idle &&
        player.idleCause == 'error') {
      stats.replacedFailureChecked++;
      if (service.playbackState == PlaybackState.playing ||
          service.playbackState == PlaybackState.loading) {
        problem(
          'a replaced queue\'s failure left the state at '
          '${service.playbackState}',
        );
      }
      if (!service.needsSourceReload) {
        problem('on a replaced queue\'s failure, but Play wouldn\'t load');
      }
      // Not at all if it failed after the replacement, once if before (and
      // stop() then ended the new queue's load): the model can't tell which
      final count = reports - reportsAtFailure;
      if (count > 1) {
        problem('a replaced queue\'s failure was reported $count times');
      }
    }

    stats.runs++;
    if (intent == _Intent.pause) {
      stats.pauseChecked++;
      if (player.playing) {
        problem('plays although the last press was Pause or Stop');
      }
    }
    if (intent == _Intent.play && !disturbed && playlist.isNotEmpty) {
      stats.playChecked++;
      if (!player.playing || service.playbackState != PlaybackState.playing) {
        problem('doesn\'t play although the last press was Play');
      }
    }
  }
}

bool _listEquals(List<String> a, List<String> b) =>
    a.length == b.length &&
    [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((same) => same);

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  test('random actions leave playback in a consistent state', () async {
    final runs = _runsOverride > 0 ? _runsOverride : _defaultRuns;
    final seeds = _seedOverride >= 0
        ? [_seedOverride]
        : [for (var seed = _firstSeed; seed < _firstSeed + runs; seed++) seed];
    final stats = _Stats();
    for (final seed in seeds) {
      final report = await _Run(seed).run(stats);
      if (report.isNotEmpty) fail(report.join('\n'));
    }
    final summary =
        '${stats.runs} runs; Pause/Stop rule checked in '
        '${stats.pauseChecked}, Play rule in ${stats.playChecked}, '
        'failure rule in ${stats.failureChecked} (on a replaced queue in '
        '${stats.replacedFailureChecked}); '
        '${stats.restores} restores (${stats.quietRestoreFailures} failed '
        'quietly), ${stats.passwordChanges} password changes '
        '(${stats.staleFailures} item loads failed only for an outdated URL), '
        '${stats.songStarts} single songs, ${stats.networkEvents} network '
        'events (${stats.networkResumes} resumed)';
    // ignore: avoid_print
    if (_runsOverride > 0) print(summary);
    if (_seedOverride < 0) {
      // Each rule about the last press is checked in a good share of the
      // runs, so a change to the model can't switch one off unnoticed
      expect(stats.pauseChecked, greaterThan(stats.runs ~/ 5), reason: summary);
      expect(stats.playChecked, greaterThan(stats.runs ~/ 5), reason: summary);
      expect(
        stats.failureChecked,
        greaterThan(stats.runs ~/ 20),
        reason: summary,
      );
      // And the paths besides the controls are taken often enough: a third
      // of the runs restore (some failing quietly), and items fail for an
      // outdated password
      expect(stats.restores, greaterThan(stats.runs ~/ 5), reason: summary);
      expect(
        stats.quietRestoreFailures,
        greaterThan(stats.runs ~/ 100),
        reason: summary,
      );
      expect(
        stats.staleFailures,
        greaterThan(stats.runs ~/ 20),
        reason: summary,
      );
      expect(stats.songStarts, greaterThan(stats.runs ~/ 2), reason: summary);
      // A failure the network caused, then nothing pressed until the
      // network comes back: rare, like a quiet restore failure
      expect(
        stats.networkResumes,
        greaterThan(stats.runs ~/ 100),
        reason: summary,
      );
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
