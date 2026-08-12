import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_translation/audio/audio_capture_gateway.dart';
import 'package:realtime_translation/audio/pcm_playback_gateway.dart';
import 'package:realtime_translation/conversation/conversation_controller.dart';
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
  _FakeAudioCapture({this.permission = true});

  final bool permission;
  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast(sync: true);
  bool started = false;
  bool stopped = false;

  void emit(List<int> bytes) => _controller.add(Uint8List.fromList(bytes));

  @override
  Future<void> dispose() async => _controller.close();

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<Stream<Uint8List>> start() async {
    started = true;
    return _controller.stream;
  }

  @override
  Future<void> stop() async => stopped = true;
}

class _FakePlayback implements PcmPlaybackGateway {
  final List<List<int>> enqueued = <List<int>>[];

  @override
  Future<void> configure() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> enqueue(Uint8List pcm) async => enqueued.add(pcm.toList());

  @override
  Future<void> flush() async {}
}

class _FakeLiveSession implements LiveTranslationSession {
  final StreamController<LiveEvent> _controller =
      StreamController<LiveEvent>.broadcast(sync: true);
  final List<List<int>> audio = <List<int>>[];
  bool closed = false;
  bool _ready = false;

  void emit(LiveEvent event) => _controller.add(event);

  @override
  Stream<LiveEvent> get events => _controller.stream;

  @override
  bool get isReady => _ready;

  @override
  Future<void> connect() async => _ready = true;

  @override
  void sendAudio(Uint8List pcm) => audio.add(pcm.toList());

  @override
  Future<void> close() async {
    closed = true;
    _ready = false;
    await _controller.close();
  }
}
