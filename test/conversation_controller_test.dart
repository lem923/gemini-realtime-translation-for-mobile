import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_translation/audio/audio_capture_gateway.dart';
import 'package:realtime_translation/audio/pcm_playback_gateway.dart';
import 'package:realtime_translation/conversation/conversation_controller.dart';
import 'package:realtime_translation/conversation/conversation_diagnostics.dart';
import 'package:realtime_translation/conversation/conversation_models.dart';
import 'package:realtime_translation/live_translate/live_event.dart';
import 'package:realtime_translation/live_translate/live_translation_session.dart';
import 'package:realtime_translation/security/api_key_store.dart';

void main() {
  test('validates a key and persists it only when requested', () async {
    final _MemoryKeyStore store = _MemoryKeyStore();
    final List<_FakeLiveSession> sessions = <_FakeLiveSession>[];
    final ConversationController controller = ConversationController(
      keyStore: store,
      audioCapture: _FakeAudioCapture(),
      playback: _FakePlayback(),
      sessionFactory:
          ({required String apiKey, required String targetLanguageCode}) {
            final _FakeLiveSession session = _FakeLiveSession();
            sessions.add(session);
            return session;
          },
    );

    await controller.initialize();
    expect(controller.phase, ConversationPhase.needsKey);
    expect(
      await controller.validateAndSaveApiKey(
        candidate: 'test-key',
        remember: true,
      ),
      isTrue,
    );
    expect(store.value, 'test-key');
    expect(controller.phase, ConversationPhase.idle);
    expect(sessions.single.closed, isTrue);

    await controller.removeApiKey();
    expect(store.value, isNull);
    expect(controller.phase, ConversationPhase.needsKey);
    controller.dispose();
  });

  test(
    'reports denied microphone permission without opening a session',
    () async {
      final _FakeAudioCapture capture = _FakeAudioCapture(permission: false);
      final ConversationController controller = ConversationController(
        keyStore: _MemoryKeyStore('stored-key'),
        audioCapture: capture,
        playback: _FakePlayback(),
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) =>
                _FakeLiveSession(),
      );

      await controller.initialize();
      await controller.startConversation();
      expect(controller.phase, ConversationPhase.permissionDenied);
      expect(controller.errorMessage, contains('麦克风权限'));
      expect(capture.started, isFalse);
      controller.dispose();
    },
  );

  test(
    'routes audio by speaker and commits transcripts with translated audio',
    () async {
      final _FakeAudioCapture capture = _FakeAudioCapture();
      final _FakePlayback playback = _FakePlayback();
      final List<_FakeLiveSession> sessions = <_FakeLiveSession>[];
      final ConversationController controller = ConversationController(
        keyStore: _MemoryKeyStore('stored-key'),
        audioCapture: capture,
        playback: playback,
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) {
              final _FakeLiveSession session = _FakeLiveSession();
              sessions.add(session);
              return session;
            },
      );

      await controller.initialize();
      await controller.startConversation();
      await _flushEvents();
      expect(controller.phase, ConversationPhase.listening);
      expect(sessions, hasLength(2));

      capture.emit(<int>[1, 2]);
      await _flushEvents();
      expect(sessions[0].audio, <List<int>>[
        <int>[1, 2],
      ]);

      await controller.selectSpeaker(SpeakerSide.b);
      capture.emit(<int>[3, 4]);
      await _flushEvents();
      expect(sessions[1].audio, <List<int>>[
        <int>[3, 4],
      ]);

      await controller.selectSpeaker(SpeakerSide.a);
      sessions[0]
        ..emit(const LiveInputTranscript('hello', 'en'))
        ..emit(const LiveOutputTranscript('你好', 'zh-Hans'))
        ..emit(LiveAudioChunk(Uint8List.fromList(<int>[5, 6, 7, 8])))
        ..emit(const LiveTurnComplete());
      await _flushEvents();
      expect(playback.enqueued, <List<int>>[
        <int>[5, 6, 7, 8],
      ]);
      expect(controller.turns, hasLength(1));
      expect(controller.turns.single.sourceText, 'hello');
      expect(controller.turns.single.translatedText, '你好');

      await controller.stopConversation();
      expect(controller.phase, ConversationPhase.idle);
      expect(capture.stopped, isTrue);
      controller.dispose();
    },
  );

  test(
    'blocks microphone capture until all queued translated audio ends',
    () async {
      int nowMicros = 0;
      final _FakeAudioCapture capture = _FakeAudioCapture();
      final List<_FakeLiveSession> sessions = <_FakeLiveSession>[];
      final ConversationController controller = ConversationController(
        keyStore: _MemoryKeyStore('stored-key'),
        audioCapture: capture,
        playback: _FakePlayback(),
        monotonicMicros: () => nowMicros,
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) {
              final _FakeLiveSession session = _FakeLiveSession();
              sessions.add(session);
              return session;
            },
      );

      await controller.initialize();
      await controller.startConversation();
      await _flushEvents();
      final Uint8List oneSecond = Uint8List(48000);
      sessions.first
        ..emit(LiveAudioChunk(oneSecond))
        ..emit(LiveAudioChunk(oneSecond));
      await _flushEvents();

      nowMicros = 1500000;
      capture.emit(<int>[1]);
      expect(sessions.first.audio, isEmpty);
      nowMicros = 2080001;
      capture.emit(<int>[2]);
      expect(sessions.first.audio, <List<int>>[
        <int>[2],
      ]);

      await controller.stopConversation();
      controller.dispose();
    },
  );

  test('stop waits for pending playback before flushing', () async {
    final Completer<void> enqueueGate = Completer<void>();
    final _FakePlayback playback = _FakePlayback(enqueueGate: enqueueGate);
    final List<_FakeLiveSession> sessions = <_FakeLiveSession>[];
    final ConversationController controller = ConversationController(
      keyStore: _MemoryKeyStore('stored-key'),
      audioCapture: _FakeAudioCapture(),
      playback: playback,
      sessionFactory:
          ({required String apiKey, required String targetLanguageCode}) {
            final _FakeLiveSession session = _FakeLiveSession();
            sessions.add(session);
            return session;
          },
    );

    await controller.initialize();
    await controller.startConversation();
    sessions.first.emit(LiveAudioChunk(Uint8List.fromList(<int>[1, 2])));
    await _flushEvents();
    final Future<void> stopping = controller.stopConversation();
    await _flushEvents();
    expect(playback.operations, <String>['configure', 'enqueue']);

    enqueueGate.complete();
    await stopping;
    expect(playback.operations, <String>['configure', 'enqueue', 'flush']);
    controller.dispose();
  });

  test(
    'playback failure falls back to text and keeps queue operable',
    () async {
      final _FakePlayback playback = _FakePlayback(failNextEnqueue: true);
      final List<_FakeLiveSession> sessions = <_FakeLiveSession>[];
      final ConversationController controller = ConversationController(
        keyStore: _MemoryKeyStore('stored-key'),
        audioCapture: _FakeAudioCapture(),
        playback: playback,
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) {
              final _FakeLiveSession session = _FakeLiveSession();
              sessions.add(session);
              return session;
            },
      );

      await controller.initialize();
      await controller.startConversation();
      sessions.first.emit(LiveAudioChunk(Uint8List.fromList(<int>[1, 2])));
      await _flushEvents();
      await _flushEvents();

      expect(controller.audioMuted, isTrue);
      expect(controller.errorMessage, contains('文字翻译'));
      await controller.stopConversation(preserveError: true);
      expect(playback.operations, contains('flush'));
      controller.dispose();
    },
  );

  test('stopping during connection prevents stale capture startup', () async {
    final Completer<void> connectGate = Completer<void>();
    final _FakeAudioCapture capture = _FakeAudioCapture();
    final List<_FakeLiveSession> sessions = <_FakeLiveSession>[];
    final ConversationController controller = ConversationController(
      keyStore: _MemoryKeyStore('stored-key'),
      audioCapture: capture,
      playback: _FakePlayback(),
      sessionFactory:
          ({required String apiKey, required String targetLanguageCode}) {
            final _FakeLiveSession session = _FakeLiveSession(
              connectGate: connectGate,
            );
            sessions.add(session);
            return session;
          },
    );

    await controller.initialize();
    final Future<void> starting = controller.startConversation();
    await _flushEvents();
    expect(sessions, hasLength(1));
    final Future<void> stopping = controller.stopConversation();
    connectGate.complete();
    await Future.wait(<Future<void>>[starting, stopping]);

    expect(capture.started, isFalse);
    expect(controller.phase, ConversationPhase.idle);
    controller.dispose();
  });

  test('coalesces simultaneous stop requests', () async {
    final List<_FakeLiveSession> sessions = <_FakeLiveSession>[];
    final ConversationController controller = ConversationController(
      keyStore: _MemoryKeyStore('stored-key'),
      audioCapture: _FakeAudioCapture(),
      playback: _FakePlayback(),
      sessionFactory:
          ({required String apiKey, required String targetLanguageCode}) {
            final _FakeLiveSession session = _FakeLiveSession();
            sessions.add(session);
            return session;
          },
    );

    await controller.initialize();
    await controller.startConversation();
    await _flushEvents();
    await Future.wait(<Future<void>>[
      controller.stopConversation(),
      controller.stopConversation(),
      controller.stopConversation(),
    ]);

    expect(sessions, isNotEmpty);
    expect(sessions.every((session) => session.closeCount == 1), isTrue);
    expect(controller.phase, ConversationPhase.idle);
    expect(controller.isBusy, isFalse);
    controller.dispose();
  });

  test(
    'a stale speaker connection cannot override the latest direction',
    () async {
      final Completer<void> speakerBGate = Completer<void>();
      final List<_FakeLiveSession> sessions = <_FakeLiveSession>[];
      final ConversationController controller = ConversationController(
        keyStore: _MemoryKeyStore('stored-key'),
        audioCapture: _FakeAudioCapture(),
        playback: _FakePlayback(),
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) {
              final _FakeLiveSession session = _FakeLiveSession(
                connectGate: sessions.isEmpty ? null : speakerBGate,
              );
              sessions.add(session);
              return session;
            },
      );

      await controller.initialize();
      await controller.startConversation();
      expect(sessions, hasLength(2));
      final Future<void> switchingToB = controller.selectSpeaker(SpeakerSide.b);
      final Future<void> switchingBackToA = controller.selectSpeaker(
        SpeakerSide.a,
      );
      await switchingBackToA;
      expect(controller.activeSpeaker, SpeakerSide.a);
      expect(controller.phase, ConversationPhase.listening);

      speakerBGate.complete();
      await switchingToB;
      expect(controller.activeSpeaker, SpeakerSide.a);
      expect(controller.phase, ConversationPhase.listening);

      await controller.stopConversation();
      controller.dispose();
    },
  );

  test(
    'maps retryable and terminal session failures to distinct phases',
    () async {
      final List<_FakeLiveSession> sessions = <_FakeLiveSession>[];
      final ConversationController controller = ConversationController(
        keyStore: _MemoryKeyStore('stored-key'),
        audioCapture: _FakeAudioCapture(),
        playback: _FakePlayback(),
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) {
              final _FakeLiveSession session = _FakeLiveSession();
              sessions.add(session);
              return session;
            },
      );

      await controller.initialize();
      await controller.startConversation();
      sessions.first.emit(
        const LiveSessionFailure(
          userMessage: '暂时错误',
          authenticationFailure: false,
          retryable: true,
        ),
      );
      expect(controller.phase, ConversationPhase.reconnecting);
      sessions.first.emit(
        const LiveSessionFailure(
          userMessage: '配额不足',
          authenticationFailure: false,
          retryable: false,
        ),
      );
      expect(controller.phase, ConversationPhase.failed);
      expect(controller.errorMessage, '配额不足');

      await controller.stopConversation();
      controller.dispose();
    },
  );

  test('terminal session failure releases resources before retry', () async {
    final Completer<void> closeGate = Completer<void>();
    final _FakeAudioCapture capture = _FakeAudioCapture();
    final List<_FakeLiveSession> sessions = <_FakeLiveSession>[];
    final ConversationController controller = ConversationController(
      keyStore: _MemoryKeyStore('stored-key'),
      audioCapture: capture,
      playback: _FakePlayback(),
      sessionFactory:
          ({required String apiKey, required String targetLanguageCode}) {
            final _FakeLiveSession session = _FakeLiveSession(
              closeGate: closeGate,
            );
            sessions.add(session);
            return session;
          },
    );

    await controller.initialize();
    await controller.startConversation();
    await _flushEvents();
    expect(capture.startCount, 1);
    sessions.first.emit(
      const LiveSessionFailure(
        userMessage: '配额已用完',
        authenticationFailure: false,
        retryable: false,
      ),
    );
    expect(controller.phase, ConversationPhase.failed);
    expect(controller.isBusy, isTrue);

    await controller.startConversation();
    expect(capture.startCount, 1);
    closeGate.complete();
    await controller.stopConversation(preserveError: true);
    expect(capture.stopped, isTrue);
    expect(sessions.every((session) => session.closed), isTrue);
    expect(controller.phase, ConversationPhase.failed);
    expect(controller.errorMessage, '配额已用完');

    await controller.startConversation();
    await _flushEvents();
    expect(capture.startCount, 2);
    expect(controller.phase, ConversationPhase.listening);
    await controller.stopConversation();
    controller.dispose();
  });

  test(
    'microphone stream failure automatically closes live sessions',
    () async {
      final _FakeAudioCapture capture = _FakeAudioCapture();
      final List<_FakeLiveSession> sessions = <_FakeLiveSession>[];
      final ConversationController controller = ConversationController(
        keyStore: _MemoryKeyStore('stored-key'),
        audioCapture: capture,
        playback: _FakePlayback(),
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) {
              final _FakeLiveSession session = _FakeLiveSession();
              sessions.add(session);
              return session;
            },
      );

      await controller.initialize();
      await controller.startConversation();
      await _flushEvents();
      capture.emitError(StateError('microphone disconnected'));
      await controller.stopConversation(preserveError: true);

      expect(controller.phase, ConversationPhase.failed);
      expect(controller.errorMessage, contains('麦克风采集失败'));
      expect(capture.stopped, isTrue);
      expect(sessions.every((session) => session.closed), isTrue);
      controller.dispose();
    },
  );

  test(
    'capture startup failure closes the already connected session',
    () async {
      final _FakeAudioCapture capture = _FakeAudioCapture(
        startError: StateError('capture unavailable'),
      );
      final List<_FakeLiveSession> sessions = <_FakeLiveSession>[];
      final ConversationController controller = ConversationController(
        keyStore: _MemoryKeyStore('stored-key'),
        audioCapture: capture,
        playback: _FakePlayback(),
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) {
              final _FakeLiveSession session = _FakeLiveSession();
              sessions.add(session);
              return session;
            },
      );

      await controller.initialize();
      await controller.startConversation();

      expect(controller.phase, ConversationPhase.failed);
      expect(controller.isBusy, isFalse);
      expect(capture.stopped, isTrue);
      expect(sessions, hasLength(1));
      expect(sessions.single.closed, isTrue);
      controller.dispose();
    },
  );

  test(
    'direction connection failure closes capture and both sessions',
    () async {
      final _FakeAudioCapture capture = _FakeAudioCapture();
      final List<_FakeLiveSession> sessions = <_FakeLiveSession>[];
      final ConversationController controller = ConversationController(
        keyStore: _MemoryKeyStore('stored-key'),
        audioCapture: capture,
        playback: _FakePlayback(),
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) {
              final _FakeLiveSession session = _FakeLiveSession(
                connectError: sessions.isEmpty
                    ? null
                    : StateError('standby unavailable'),
              );
              sessions.add(session);
              return session;
            },
      );

      await controller.initialize();
      await controller.startConversation();
      await _flushEvents();
      await controller.selectSpeaker(SpeakerSide.b);
      await controller.stopConversation(preserveError: true);

      expect(controller.phase, ConversationPhase.failed);
      expect(controller.errorMessage, contains('切换方向失败'));
      expect(capture.stopped, isTrue);
      expect(sessions, hasLength(2));
      expect(sessions.every((session) => session.closed), isTrue);
      controller.dispose();
    },
  );

  test('bounds long conversation history to the latest 200 turns', () async {
    final List<_FakeLiveSession> sessions = <_FakeLiveSession>[];
    final ConversationController controller = ConversationController(
      keyStore: _MemoryKeyStore('stored-key'),
      audioCapture: _FakeAudioCapture(),
      playback: _FakePlayback(),
      sessionFactory:
          ({required String apiKey, required String targetLanguageCode}) {
            final _FakeLiveSession session = _FakeLiveSession();
            sessions.add(session);
            return session;
          },
    );

    await controller.initialize();
    await controller.startConversation();
    for (int index = 1; index <= 250; index += 1) {
      sessions.first
        ..emit(LiveInputTranscript('source $index', 'en'))
        ..emit(LiveOutputTranscript('target $index', 'zh-Hans'))
        ..emit(const LiveTurnComplete());
    }

    expect(controller.turns, hasLength(ConversationController.maxHistoryTurns));
    expect(controller.turns.first.id, 51);
    expect(controller.turns.last.id, 250);
    await controller.stopConversation();
    controller.dispose();
  });

  test('collects bounded redacted session and playback diagnostics', () async {
    int nowMicros = 1000000;
    final _FakeAudioCapture capture = _FakeAudioCapture();
    final _FakePlayback playback = _FakePlayback(
      playbackMetrics: const PcmPlaybackMetrics(
        queuedBytes: 2400,
        maxQueuedBytes: 72000,
        droppedChunks: 2,
      ),
    );
    final List<_FakeLiveSession> sessions = <_FakeLiveSession>[];
    final ConversationController controller = ConversationController(
      keyStore: _MemoryKeyStore('stored-key'),
      audioCapture: capture,
      playback: playback,
      monotonicMicros: () => nowMicros,
      sessionFactory:
          ({required String apiKey, required String targetLanguageCode}) {
            final _FakeLiveSession session = _FakeLiveSession();
            sessions.add(session);
            return session;
          },
    );

    await controller.initialize();
    await controller.startConversation();
    capture.emit(<int>[1, 2]);
    nowMicros = 1050000;
    sessions.first.emit(const LiveInputTranscript('secret source', 'en'));
    nowMicros = 1070000;
    sessions.first.emit(const LiveOutputTranscript('秘密译文', 'zh-Hans'));
    nowMicros = 1080000;
    sessions.first.emit(LiveAudioChunk(Uint8List(4800)));
    nowMicros = 1090000;
    capture.emit(<int>[3, 4]);
    sessions.first
      ..emit(const LiveTurnComplete())
      ..emit(const LivePhaseChanged(LiveSessionPhase.reconnecting))
      ..emit(
        const LiveSessionFailure(
          userMessage: '暂时不可用',
          authenticationFailure: false,
          retryable: true,
        ),
      );
    await controller.selectSpeaker(SpeakerSide.b);
    nowMicros = 1200000;

    final ConversationDiagnostics diagnostics = await controller
        .collectDiagnostics();
    expect(diagnostics.sessionDurationMilliseconds, 200);
    expect(diagnostics.microphoneChunksSent, 1);
    expect(diagnostics.microphoneChunksSuppressed, 1);
    expect(diagnostics.outputAudioChunks, 1);
    expect(diagnostics.outputAudioBytes, 4800);
    expect(diagnostics.completedTurns, 1);
    expect(diagnostics.directionSwitches, 1);
    expect(diagnostics.reconnectEvents, 1);
    expect(diagnostics.sessionFailures, 1);
    expect(diagnostics.listeningReadyMilliseconds, 0);
    expect(diagnostics.firstMicrophoneSentMilliseconds, 0);
    expect(diagnostics.firstSourceTextMilliseconds, 50);
    expect(diagnostics.firstTranslatedTextMilliseconds, 70);
    expect(diagnostics.firstTranslatedAudioMilliseconds, 80);
    expect(diagnostics.maximumScheduledPlaybackMilliseconds, 100);
    expect(diagnostics.playbackMetrics.queuedMilliseconds, 50);
    expect(diagnostics.playbackMetrics.maximumQueueMilliseconds, 1500);
    expect(diagnostics.playbackMetrics.droppedChunks, 2);
    expect(diagnostics.playbackMetricsAvailable, isTrue);

    final String report = diagnostics.toRedactedText();
    expect(report, isNot(contains('secret source')));
    expect(report, isNot(contains('秘密译文')));
    expect(report, isNot(contains('stored-key')));
    expect(report, contains('不含 Key、音频或对话内容'));

    nowMicros = 1300000;
    await controller.stopConversation();
    nowMicros = 2000000;
    final ConversationDiagnostics stopped = await controller
        .collectDiagnostics();
    expect(stopped.sessionDurationMilliseconds, 300);
    controller.dispose();
  });
}

Future<void> _flushEvents() => Future<void>.delayed(Duration.zero);

class _MemoryKeyStore implements ApiKeyStore {
  _MemoryKeyStore([this.value]);

  String? value;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

class _FakeAudioCapture implements AudioCaptureGateway {
  _FakeAudioCapture({this.permission = true, this.startError});

  final bool permission;
  final Object? startError;
  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast(sync: true);
  bool started = false;
  bool stopped = false;
  int startCount = 0;

  void emit(List<int> bytes) => _controller.add(Uint8List.fromList(bytes));

  void emitError(Object error) => _controller.addError(error);

  @override
  Future<void> dispose() async => _controller.close();

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<Stream<Uint8List>> start() async {
    started = true;
    startCount += 1;
    final Object? error = startError;
    if (error != null) {
      throw error;
    }
    return _controller.stream;
  }

  @override
  Future<void> stop() async => stopped = true;
}

class _FakePlayback implements PcmPlaybackGateway {
  _FakePlayback({
    this.enqueueGate,
    this.failNextEnqueue = false,
    this.playbackMetrics = const PcmPlaybackMetrics.empty(),
  });

  final Completer<void>? enqueueGate;
  bool failNextEnqueue;
  final PcmPlaybackMetrics playbackMetrics;
  final List<List<int>> enqueued = <List<int>>[];
  final List<String> operations = <String>[];

  @override
  Future<void> configure() async => operations.add('configure');

  @override
  Future<void> dispose() async {}

  @override
  Future<void> enqueue(Uint8List pcm) async {
    operations.add('enqueue');
    enqueued.add(pcm.toList());
    if (failNextEnqueue) {
      failNextEnqueue = false;
      throw StateError('playback failed');
    }
    await enqueueGate?.future;
  }

  @override
  Future<void> flush() async => operations.add('flush');

  @override
  Future<PcmPlaybackMetrics> metrics() async => playbackMetrics;
}

class _FakeLiveSession implements LiveTranslationSession {
  _FakeLiveSession({this.connectGate, this.closeGate, this.connectError});

  final Completer<void>? connectGate;
  final Completer<void>? closeGate;
  final Object? connectError;
  final StreamController<LiveEvent> _controller =
      StreamController<LiveEvent>.broadcast(sync: true);
  final List<List<int>> audio = <List<int>>[];
  bool closed = false;
  int closeCount = 0;
  bool _ready = false;

  void emit(LiveEvent event) => _controller.add(event);

  @override
  Stream<LiveEvent> get events => _controller.stream;

  @override
  bool get isReady => _ready;

  @override
  Future<void> connect() async {
    await connectGate?.future;
    final Object? error = connectError;
    if (error != null) {
      throw error;
    }
    if (!closed) {
      _ready = true;
    }
  }

  @override
  void sendAudio(Uint8List pcm) => audio.add(pcm.toList());

  @override
  Future<void> close() async {
    closeCount += 1;
    closed = true;
    _ready = false;
    await closeGate?.future;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}
