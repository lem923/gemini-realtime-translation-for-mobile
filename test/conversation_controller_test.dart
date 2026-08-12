import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_translation/audio/audio_capture_gateway.dart';
import 'package:realtime_translation/audio/pcm_playback_gateway.dart';
import 'package:realtime_translation/conversation/conversation_controller.dart';
import 'package:realtime_translation/conversation/conversation_diagnostics.dart';
import 'package:realtime_translation/conversation/conversation_models.dart';
import 'package:realtime_translation/live_translate/live_event.dart';
import 'package:realtime_translation/live_translate/live_translation_session.dart';
import 'package:realtime_translation/permissions/microphone_permission_gateway.dart';
import 'package:realtime_translation/preferences/language_pair_store.dart';
import 'package:realtime_translation/security/api_key_store.dart';
import 'package:realtime_translation/shared/translation_language.dart';

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

  test('restores and persists only the last valid language pair', () async {
    final _MemoryLanguagePairStore languageStore = _MemoryLanguagePairStore(
      const StoredLanguagePair(languageA: 'ja', languageB: 'fr'),
    );
    final ConversationController controller = ConversationController(
      keyStore: _MemoryKeyStore('stored-key'),
      languagePairStore: languageStore,
      audioCapture: _FakeAudioCapture(),
      playback: _FakePlayback(),
      sessionFactory:
          ({required String apiKey, required String targetLanguageCode}) =>
              _FakeLiveSession(),
    );

    await controller.initialize();
    expect(controller.languageA.code, 'ja');
    expect(controller.languageB.code, 'fr');

    await controller.setLanguage(SpeakerSide.a, languageByCode('de'));
    expect(languageStore.value?.languageA, 'de');
    expect(languageStore.value?.languageB, 'fr');
    await controller.swapLanguages();
    expect(languageStore.value?.languageA, 'fr');
    expect(languageStore.value?.languageB, 'de');
    controller.dispose();
  });

  test('ignores corrupt, unsupported, or duplicate persisted pairs', () async {
    for (final StoredLanguagePair pair in <StoredLanguagePair>[
      const StoredLanguagePair(languageA: 'unknown', languageB: 'en'),
      const StoredLanguagePair(languageA: 'en', languageB: 'en'),
    ]) {
      final ConversationController controller = ConversationController(
        keyStore: _MemoryKeyStore('stored-key'),
        languagePairStore: _MemoryLanguagePairStore(pair),
        audioCapture: _FakeAudioCapture(),
        playback: _FakePlayback(),
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) =>
                _FakeLiveSession(),
      );

      await controller.initialize();
      expect(controller.languageA.code, 'zh-Hans');
      expect(controller.languageB.code, 'en');
      controller.dispose();
    }
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
    'restores from denied permission and stops immediately when revoked',
    () async {
      final _FakeAudioCapture capture = _FakeAudioCapture();
      final _FakeMicrophonePermissionGateway permissions =
          _FakeMicrophonePermissionGateway(MicrophonePermissionStatus.denied);
      final ConversationController controller = ConversationController(
        keyStore: _MemoryKeyStore('stored-key'),
        audioCapture: capture,
        playback: _FakePlayback(),
        permissionGateway: permissions,
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) =>
                _FakeLiveSession(),
      );

      await controller.initialize();
      expect(controller.phase, ConversationPhase.permissionDenied);
      expect(capture.started, isFalse);

      permissions.emit(MicrophonePermissionStatus.granted);
      expect(controller.phase, ConversationPhase.idle);
      await controller.startConversation();
      expect(controller.phase, ConversationPhase.listening);

      permissions.emit(MicrophonePermissionStatus.denied);
      await _flushEvents();
      expect(controller.phase, ConversationPhase.permissionDenied);
      expect(controller.errorMessage, contains('已被撤销'));
      expect(capture.stopped, isTrue);

      await controller.openMicrophoneSettings();
      expect(permissions.openSettingsCount, 1);
      controller.dispose();
    },
  );

  test(
    'does not treat an unrequested microphone permission as denied',
    () async {
      final _FakeAudioCapture capture = _FakeAudioCapture(permission: false);
      final _FakeMicrophonePermissionGateway permissions =
          _FakeMicrophonePermissionGateway(
            MicrophonePermissionStatus.notDetermined,
          );
      final ConversationController controller = ConversationController(
        keyStore: _MemoryKeyStore('stored-key'),
        audioCapture: capture,
        playback: _FakePlayback(),
        permissionGateway: permissions,
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) =>
                _FakeLiveSession(),
      );

      await controller.initialize();
      expect(controller.phase, ConversationPhase.idle);
      permissions.emit(MicrophonePermissionStatus.notDetermined);
      expect(controller.phase, ConversationPhase.idle);

      await controller.startConversation();
      expect(controller.phase, ConversationPhase.permissionDenied);
      expect(capture.started, isFalse);
      expect(permissions.requestResults, <bool>[false]);
      controller.dispose();
    },
  );

  test(
    'initial network failure remains an explicit retryable offline state',
    () async {
      final _FakeAudioCapture capture = _FakeAudioCapture();
      final ConversationController controller = ConversationController(
        keyStore: _MemoryKeyStore('stored-key'),
        audioCapture: capture,
        playback: _FakePlayback(),
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) =>
                _FakeLiveSession(
                  connectError: const SocketException('offline'),
                  connectFailureEvent: const LiveSessionFailure(
                    userMessage: '无法连接 Gemini，请检查网络',
                    authenticationFailure: false,
                    retryable: false,
                    kind: LiveFailureKind.offline,
                  ),
                ),
      );

      await controller.initialize();
      await controller.startConversation();

      expect(controller.phase, ConversationPhase.offline);
      expect(controller.errorMessage, contains('网络'));
      expect(controller.isBusy, isFalse);
      expect(capture.started, isFalse);
      controller.dispose();
    },
  );

  test(
    'connection throw cannot overwrite a preceding retryable offline event',
    () async {
      final _FakeAudioCapture capture = _FakeAudioCapture();
      final ConversationController controller = ConversationController(
        keyStore: _MemoryKeyStore('stored-key'),
        audioCapture: capture,
        playback: _FakePlayback(),
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) =>
                _FakeLiveSession(
                  connectError: const SocketException('reset after ready'),
                  connectFailureEvent: const LiveSessionFailure(
                    userMessage: '网络连接中断，恢复后将自动重连',
                    authenticationFailure: false,
                    retryable: true,
                    kind: LiveFailureKind.offline,
                  ),
                ),
      );

      await controller.initialize();
      await controller.startConversation();

      expect(controller.phase, ConversationPhase.offline);
      expect(controller.errorMessage, contains('网络连接中断'));
      expect(controller.isBusy, isFalse);
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
      expect(sessions.first.endAudioStreamCount, 1);
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
      expect(sessions[1].endAudioStreamCount, 1);
      expect(controller.phase, ConversationPhase.idle);
      expect(capture.stopped, isTrue);
      controller.dispose();
    },
  );

  test(
    'manual speaker switch commits output without a server turn-complete event',
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
      sessions.first
        ..emit(const LiveInputTranscript('你好', 'zh-Hans'))
        ..emit(const LiveOutputTranscript('hello', 'en'))
        ..emit(LiveAudioChunk(Uint8List(4800)));
      await _flushEvents();

      expect(controller.phase, ConversationPhase.translating);
      expect(controller.turns, isEmpty);
      await controller.selectSpeaker(SpeakerSide.b);

      expect(controller.phase, ConversationPhase.listening);
      expect(controller.turns, hasLength(1));
      expect(controller.turns.single.sourceText, '你好');
      expect(controller.turns.single.translatedText, 'hello');
      expect(controller.hasReplayAudio(controller.turns.single.id), isTrue);
      expect(playback.operations, contains('flush'));

      await controller.stopConversation();
      controller.dispose();
    },
  );

  test('ignores late events from the inactive speaker session', () async {
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
    await controller.selectSpeaker(SpeakerSide.b);

    sessions.first
      ..emit(const LiveInputTranscript('stale source', 'en'))
      ..emit(const LiveOutputTranscript('过期译文', 'zh-Hans'))
      ..emit(LiveAudioChunk(Uint8List(4800)))
      ..emit(const LiveTurnComplete());
    await _flushEvents();

    expect(controller.turns, isEmpty);
    expect(controller.interimSource, isEmpty);
    expect(controller.interimTranslation, isEmpty);

    await controller.selectSpeaker(SpeakerSide.a);
    expect(controller.interimSource, isEmpty);
    expect(controller.interimTranslation, isEmpty);
    sessions.first
      ..emit(const LiveInputTranscript('fresh source', 'en'))
      ..emit(const LiveOutputTranscript('新译文', 'zh-Hans'))
      ..emit(const LiveTurnComplete());
    await _flushEvents();

    expect(controller.turns, hasLength(1));
    expect(controller.turns.single.sourceText, 'fresh source');
    expect(controller.turns.single.translatedText, '新译文');

    await controller.stopConversation();
    controller.dispose();
  });

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
    expect(playback.operations, <String>[
      'configure',
      'enqueue',
      'flush',
      'dispose',
    ]);
    controller.dispose();
  });

  test(
    'speaker switch flushes stale translation and reopens the new direction',
    () async {
      int nowMicros = 0;
      final _FakeAudioCapture capture = _FakeAudioCapture();
      final _FakePlayback playback = _FakePlayback();
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
      await _flushEvents();
      sessions.first.emit(LiveAudioChunk(Uint8List(48000)));
      await _flushEvents();

      capture.emit(<int>[1]);
      expect(sessions.first.audio, isEmpty);
      await controller.selectSpeaker(SpeakerSide.b);
      expect(playback.operations, <String>['configure', 'enqueue', 'flush']);

      capture.emit(<int>[2]);
      expect(sessions[1].audio, <List<int>>[
        <int>[2],
      ]);
      expect(controller.phase, ConversationPhase.listening);

      nowMicros = 1;
      await controller.stopConversation();
      controller.dispose();
    },
  );

  test(
    'speaker switch keeps text available when playback flush fails',
    () async {
      final _FakePlayback playback = _FakePlayback(failNextFlush: true);
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
      await _flushEvents();
      await controller.selectSpeaker(SpeakerSide.b);

      expect(controller.activeSpeaker, SpeakerSide.b);
      expect(controller.phase, ConversationPhase.listening);
      expect(controller.audioMuted, isTrue);
      expect(controller.errorMessage, contains('文字翻译'));

      await controller.stopConversation(preserveError: true);
      controller.dispose();
    },
  );

  test('speaker switch does not route capture until flush completes', () async {
    final Completer<void> flushGate = Completer<void>();
    final _FakeAudioCapture capture = _FakeAudioCapture();
    final _FakePlayback playback = _FakePlayback(flushGate: flushGate);
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
    final Future<void> switching = controller.selectSpeaker(SpeakerSide.b);
    await _flushEvents();

    expect(controller.phase, ConversationPhase.connecting);
    capture.emit(<int>[1]);
    expect(sessions[1].audio, isEmpty);

    flushGate.complete();
    await switching;
    capture.emit(<int>[2]);
    expect(sessions[1].audio, <List<int>>[
      <int>[2],
    ]);

    await controller.stopConversation();
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

  test(
    'system audio interruption releases capture and live sessions',
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
      playback
        ..emitInterruption()
        ..emitInterruption();
      await _flushEvents();
      await _flushEvents();

      expect(controller.phase, ConversationPhase.failed);
      expect(controller.errorMessage, contains('系统中断'));
      expect(capture.stopped, isTrue);
      expect(sessions.every((session) => session.closed), isTrue);
      expect(playback.operations, contains('flush'));
      final ConversationDiagnostics diagnostics = await controller
          .collectDiagnostics();
      expect(diagnostics.audioInterruptions, 1);

      controller.dispose();
    },
  );

  test(
    'replays completed translated audio and releases idle playback',
    () async {
      final _FakePlayback playback = _FakePlayback();
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
      final Uint8List replayAudio = Uint8List.fromList(
        List<int>.generate(4800, (int index) => index & 0xff),
      );
      sessions.first
        ..emit(const LiveInputTranscript('hello', 'en'))
        ..emit(const LiveOutputTranscript('你好', 'zh-Hans'))
        ..emit(LiveAudioChunk(replayAudio))
        ..emit(const LiveTurnComplete());
      await _flushEvents();
      final int turnId = controller.turns.single.id;
      expect(controller.hasReplayAudio(turnId), isTrue);

      await controller.stopConversation();
      final int enqueuesBeforeReplay = playback.enqueued.length;
      await controller.replayTurn(turnId);

      expect(playback.enqueued.length, enqueuesBeforeReplay + 1);
      expect(playback.enqueued.last, replayAudio);
      expect(
        playback.operations.where((value) => value == 'configure'),
        hasLength(2),
      );
      expect(playback.disposeCount, greaterThanOrEqualTo(2));
      expect(controller.replayingTurnId, isNull);
      controller.dispose();
    },
  );

  test(
    'active replay blocks capture and can be cancelled immediately',
    () async {
      int nowMicros = 0;
      final _FakeAudioCapture capture = _FakeAudioCapture();
      final _FakePlayback playback = _FakePlayback();
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
      sessions.first
        ..emit(const LiveInputTranscript('hello', 'en'))
        ..emit(const LiveOutputTranscript('你好', 'zh-Hans'))
        ..emit(LiveAudioChunk(Uint8List(48000)))
        ..emit(const LiveTurnComplete());
      await _flushEvents();
      final Future<void> replay = controller.replayTurn(
        controller.turns.single.id,
      );
      await _flushEvents();
      expect(controller.replayingTurnId, isNotNull);

      capture.emit(<int>[1]);
      expect(sessions.first.audio, isEmpty);
      await controller.stopReplay();
      await replay;
      expect(controller.replayingTurnId, isNull);

      nowMicros = 2000000;
      capture.emit(<int>[2]);
      expect(sessions.first.audio, <List<int>>[
        <int>[2],
      ]);
      await controller.stopConversation();
      controller.dispose();
    },
  );

  test(
    'fresh translated audio interrupts replay without dropping output',
    () async {
      final _FakePlayback playback = _FakePlayback();
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
      sessions.first
        ..emit(const LiveInputTranscript('hello', 'en'))
        ..emit(const LiveOutputTranscript('你好', 'zh-Hans'))
        ..emit(LiveAudioChunk(Uint8List(48000)))
        ..emit(const LiveTurnComplete());
      await _flushEvents();
      final Future<void> replay = controller.replayTurn(
        controller.turns.single.id,
      );
      await _flushEvents();
      expect(controller.replayingTurnId, isNotNull);

      final Uint8List freshAudio = Uint8List.fromList(<int>[9, 8, 7, 6]);
      sessions.first.emit(LiveAudioChunk(freshAudio));
      await _flushEvents();
      await replay;

      expect(controller.replayingTurnId, isNull);
      expect(playback.enqueued.last, freshAudio);
      await controller.stopConversation();
      controller.dispose();
    },
  );

  test('does not retain an oversized turn for replay', () async {
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
    sessions.first
      ..emit(const LiveInputTranscript('long turn', 'en'))
      ..emit(const LiveOutputTranscript('长句', 'zh-Hans'))
      ..emit(
        LiveAudioChunk(
          Uint8List(ConversationController.maxReplayTurnBytes + 1),
        ),
      )
      ..emit(const LiveTurnComplete());
    await _flushEvents();

    expect(controller.turns, hasLength(1));
    expect(controller.hasReplayAudio(controller.turns.single.id), isFalse);
    await controller.stopConversation();
    controller.dispose();
  });

  test('evicts oldest replay audio while preserving text history', () async {
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
    controller.toggleAudioMuted();
    const int audioBytes = 1400000;
    for (int index = 0; index < 6; index += 1) {
      sessions.first
        ..emit(LiveInputTranscript('source $index', 'en'))
        ..emit(LiveOutputTranscript('translated $index', 'zh-Hans'))
        ..emit(LiveAudioChunk(Uint8List(audioBytes)))
        ..emit(const LiveTurnComplete());
    }
    await _flushEvents();

    expect(controller.turns, hasLength(6));
    expect(controller.hasReplayAudio(controller.turns.first.id), isFalse);
    expect(controller.hasReplayAudio(controller.turns.last.id), isTrue);
    controller.clearHistory();
    expect(controller.turns, isEmpty);
    expect(controller.hasReplayAudio(6), isFalse);
    await controller.stopConversation();
    controller.dispose();
  });

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
    expect(controller.phase, ConversationPhase.connecting);
    expect(controller.canStopConversation, isTrue);
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
      final _FakePlayback playback = _FakePlayback();
      final List<_FakeLiveSession> sessions = <_FakeLiveSession>[];
      final ConversationController controller = ConversationController(
        keyStore: _MemoryKeyStore('stored-key'),
        audioCapture: _FakeAudioCapture(),
        playback: playback,
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
      expect(
        playback.operations.where((value) => value == 'flush'),
        hasLength(2),
      );

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

  test(
    'exposes translating, offline recovery, and rate-limit states',
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
      sessions.first.emit(const LiveOutputTranscript('你好', 'zh-Hans'));
      expect(controller.phase, ConversationPhase.translating);
      expect(controller.isListening, isTrue);
      sessions.first.emit(const LiveTurnComplete());
      expect(controller.phase, ConversationPhase.listening);

      sessions.first.emit(
        const LiveSessionFailure(
          userMessage: '网络连接中断，恢复后将自动重连',
          authenticationFailure: false,
          retryable: true,
          kind: LiveFailureKind.offline,
        ),
      );
      expect(controller.phase, ConversationPhase.offline);
      expect(controller.isBusy, isTrue);
      expect(controller.canStopConversation, isTrue);
      sessions.first.emit(
        const LivePhaseChanged(LiveSessionPhase.reconnecting),
      );
      expect(controller.phase, ConversationPhase.offline);
      sessions.first.emit(const LivePhaseChanged(LiveSessionPhase.ready));
      expect(controller.phase, ConversationPhase.listening);

      sessions.first.emit(
        const LiveSessionFailure(
          userMessage: '配额不足',
          authenticationFailure: false,
          retryable: false,
          kind: LiveFailureKind.rateLimited,
        ),
      );
      expect(controller.phase, ConversationPhase.rateLimited);
      await _flushEvents();
      await _flushEvents();
      expect(capture.stopped, isTrue);
      expect(controller.isBusy, isFalse);
      expect(controller.canStopConversation, isFalse);
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

  test('keeps a logical 20-minute media session bounded', () async {
    int nowMicros = 0;
    final _FakeAudioCapture capture = _FakeAudioCapture();
    final _FakePlayback playback = _FakePlayback();
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
    controller.toggleAudioMuted();
    const int logicalChunks = 20 * 60 * 10;
    const int chunksPerTurn = 50;
    const int audioChunksPerTurn = 10;
    for (int chunkIndex = 1; chunkIndex <= logicalChunks; chunkIndex += 1) {
      nowMicros += 100000;
      capture.emit(<int>[chunkIndex & 0xff, (chunkIndex >> 8) & 0xff]);
      if (chunkIndex % chunksPerTurn != 0) {
        continue;
      }
      final int turn = chunkIndex ~/ chunksPerTurn;
      sessions.first
        ..emit(LiveInputTranscript('source $turn', 'zh-Hans'))
        ..emit(LiveOutputTranscript('target $turn', 'en'));
      for (
        int audioIndex = 0;
        audioIndex < audioChunksPerTurn;
        audioIndex += 1
      ) {
        sessions.first.emit(LiveAudioChunk(Uint8List(4800)));
      }
      sessions.first.emit(const LiveTurnComplete());
    }

    final ConversationDiagnostics diagnostics = await controller
        .collectDiagnostics();
    expect(diagnostics.sessionDurationMilliseconds, 20 * 60 * 1000);
    expect(
      diagnostics.microphoneChunksSent + diagnostics.microphoneChunksSuppressed,
      logicalChunks,
    );
    expect(diagnostics.completedTurns, 240);
    expect(diagnostics.outputAudioBytes, 240 * 48000);
    expect(controller.turns, hasLength(ConversationController.maxHistoryTurns));
    expect(controller.turns.first.id, 41);
    expect(controller.turns.last.id, 240);
    expect(controller.hasReplayAudio(41), isFalse);
    expect(controller.hasReplayAudio(240), isTrue);
    expect(playback.enqueued, isEmpty);

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
        outputRoute: AudioOutputRoute.speaker,
        audioFocusGranted: true,
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
    sessions.first
      ..emit(
        const LiveUsageMetadata(
          promptTokenCount: 100,
          responseTokenCount: 20,
          totalTokenCount: 120,
        ),
      )
      ..emit(
        const LiveUsageMetadata(
          promptTokenCount: 140,
          responseTokenCount: 35,
          totalTokenCount: 175,
        ),
      );
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
    sessions[1].emit(
      const LiveUsageMetadata(
        promptTokenCount: 80,
        responseTokenCount: 15,
        totalTokenCount: 95,
      ),
    );
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
    expect(diagnostics.geminiPromptTokens, 320);
    expect(diagnostics.geminiResponseTokens, 70);
    expect(diagnostics.geminiTotalTokens, 390);
    expect(diagnostics.geminiUsageAvailable, isTrue);
    expect(diagnostics.listeningReadyMilliseconds, 0);
    expect(diagnostics.firstMicrophoneSentMilliseconds, 0);
    expect(diagnostics.firstSourceTextMilliseconds, 50);
    expect(diagnostics.firstTranslatedTextMilliseconds, 70);
    expect(diagnostics.firstTranslatedAudioMilliseconds, 80);
    expect(diagnostics.maximumScheduledPlaybackMilliseconds, 100);
    expect(diagnostics.playbackMetrics.queuedMilliseconds, 50);
    expect(diagnostics.playbackMetrics.maximumQueueMilliseconds, 1500);
    expect(diagnostics.playbackMetrics.droppedChunks, 2);
    expect(diagnostics.playbackMetrics.outputRoute, AudioOutputRoute.speaker);
    expect(diagnostics.playbackMetrics.audioFocusGranted, isTrue);
    expect(diagnostics.playbackMetricsAvailable, isTrue);

    final String report = diagnostics.toRedactedText();
    expect(report, isNot(contains('secret source')));
    expect(report, isNot(contains('秘密译文')));
    expect(report, isNot(contains('stored-key')));
    expect(report, contains('不含 Key、音频或对话内容'));
    expect(report, contains('320 / 70 / 390'));

    nowMicros = 1300000;
    await controller.stopConversation();
    nowMicros = 2000000;
    final ConversationDiagnostics stopped = await controller
        .collectDiagnostics();
    expect(stopped.sessionDurationMilliseconds, 300);

    await controller.startConversation();
    final ConversationDiagnostics restarted = await controller
        .collectDiagnostics();
    expect(restarted.geminiPromptTokens, 0);
    expect(restarted.geminiResponseTokens, 0);
    expect(restarted.geminiTotalTokens, 0);
    expect(restarted.geminiUsageAvailable, isFalse);
    await controller.stopConversation();
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

class _MemoryLanguagePairStore implements LanguagePairStore {
  _MemoryLanguagePairStore([this.value]);

  StoredLanguagePair? value;

  @override
  Future<StoredLanguagePair?> read() async => value;

  @override
  Future<void> write(StoredLanguagePair pair) async {
    value = pair;
  }
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

class _FakeMicrophonePermissionGateway implements MicrophonePermissionGateway {
  _FakeMicrophonePermissionGateway(this.status);

  MicrophonePermissionStatus? status;
  int openSettingsCount = 0;
  final List<bool> requestResults = <bool>[];
  final StreamController<MicrophonePermissionStatus> _changes =
      StreamController<MicrophonePermissionStatus>.broadcast(sync: true);

  void emit(MicrophonePermissionStatus nextStatus) {
    status = nextStatus;
    _changes.add(nextStatus);
  }

  @override
  Stream<MicrophonePermissionStatus> get changes => _changes.stream;

  @override
  Future<MicrophonePermissionStatus?> currentStatus() async => status;

  @override
  Future<void> openAppSettings() async {
    openSettingsCount += 1;
  }

  @override
  Future<void> recordRequestResult({required bool granted}) async {
    requestResults.add(granted);
  }
}

class _FakePlayback implements PcmPlaybackGateway {
  _FakePlayback({
    this.enqueueGate,
    this.flushGate,
    this.failNextEnqueue = false,
    this.failNextFlush = false,
    this.playbackMetrics = const PcmPlaybackMetrics.empty(),
  });

  final Completer<void>? enqueueGate;
  final Completer<void>? flushGate;
  bool failNextEnqueue;
  bool failNextFlush;
  final PcmPlaybackMetrics playbackMetrics;
  final StreamController<PcmPlaybackEvent> _events =
      StreamController<PcmPlaybackEvent>.broadcast(sync: true);
  final List<List<int>> enqueued = <List<int>>[];
  final List<String> operations = <String>[];
  int disposeCount = 0;

  void emitInterruption() => _events.add(const PcmPlaybackInterrupted());

  @override
  Stream<PcmPlaybackEvent> get events => _events.stream;

  @override
  Future<void> configure() async => operations.add('configure');

  @override
  Future<void> dispose() async {
    disposeCount += 1;
    operations.add('dispose');
  }

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
  Future<void> flush() async {
    operations.add('flush');
    if (failNextFlush) {
      failNextFlush = false;
      throw StateError('flush failed');
    }
    await flushGate?.future;
  }

  @override
  Future<PcmPlaybackMetrics> metrics() async => playbackMetrics;
}

class _FakeLiveSession implements LiveTranslationSession {
  _FakeLiveSession({
    this.connectGate,
    this.closeGate,
    this.connectError,
    this.connectFailureEvent,
  });

  final Completer<void>? connectGate;
  final Completer<void>? closeGate;
  final Object? connectError;
  final LiveSessionFailure? connectFailureEvent;
  final StreamController<LiveEvent> _controller =
      StreamController<LiveEvent>.broadcast(sync: true);
  final List<List<int>> audio = <List<int>>[];
  bool closed = false;
  int closeCount = 0;
  int endAudioStreamCount = 0;
  bool _ready = false;

  void emit(LiveEvent event) => _controller.add(event);

  @override
  Stream<LiveEvent> get events => _controller.stream;

  @override
  bool get isReady => _ready;

  @override
  Future<void> connect() async {
    await connectGate?.future;
    final LiveSessionFailure? failure = connectFailureEvent;
    if (failure != null) {
      _controller.add(failure);
    }
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
  void endAudioStream() => endAudioStreamCount += 1;

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
