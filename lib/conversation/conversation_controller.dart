import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';

import '../audio/audio_capture_gateway.dart';
import '../audio/audio_constants.dart';
import '../audio/pcm_playback_gateway.dart';
import '../live_translate/live_event.dart';
import '../live_translate/live_translation_session.dart';
import '../security/api_key_store.dart';
import '../shared/translation_language.dart';
import 'conversation_models.dart';

class ConversationController extends ChangeNotifier {
  ConversationController({
    ApiKeyStore? keyStore,
    AudioCaptureGateway? audioCapture,
    PcmPlaybackGateway? playback,
    LiveSessionFactory? sessionFactory,
  }) : _keyStore = keyStore ?? SecureApiKeyStore(),
       _audioCapture = audioCapture ?? RecordAudioCaptureGateway(),
       _playback = playback ?? PlatformPcmPlaybackGateway(),
       _sessionFactory =
           sessionFactory ??
           (({required String apiKey, required String targetLanguageCode}) =>
               GeminiLiveSession(
                 apiKey: apiKey,
                 targetLanguageCode: targetLanguageCode,
               ));

  final ApiKeyStore _keyStore;
  final AudioCaptureGateway _audioCapture;
  final PcmPlaybackGateway _playback;
  final LiveSessionFactory _sessionFactory;
  final Stopwatch _monotonicClock = Stopwatch()..start();
  final Map<SpeakerSide, LiveTranslationSession> _sessions =
      <SpeakerSide, LiveTranslationSession>{};
  final Map<SpeakerSide, StreamSubscription<LiveEvent>> _sessionSubscriptions =
      <SpeakerSide, StreamSubscription<LiveEvent>>{};
  final Map<SpeakerSide, TranscriptAccumulator> _sourceTranscripts =
      <SpeakerSide, TranscriptAccumulator>{
        SpeakerSide.a: TranscriptAccumulator(),
        SpeakerSide.b: TranscriptAccumulator(),
      };
  final Map<SpeakerSide, TranscriptAccumulator> _translatedTranscripts =
      <SpeakerSide, TranscriptAccumulator>{
        SpeakerSide.a: TranscriptAccumulator(),
        SpeakerSide.b: TranscriptAccumulator(),
      };

  StreamSubscription<Uint8List>? _captureSubscription;
  Future<void> _playbackChain = Future<void>.value();
  String _apiKey = '';
  bool _rememberKey = false;
  bool _initialized = false;
  bool _audioMuted = false;
  bool _disposed = false;
  int _captureBlockedUntilMicros = 0;
  int _turnId = 0;
  String? _errorMessage;
  ConversationPhase _phase = ConversationPhase.needsKey;
  SpeakerSide _activeSpeaker = SpeakerSide.a;
  TranslationLanguage _languageA = languageByCode('zh-Hans');
  TranslationLanguage _languageB = languageByCode('en');
  final List<ConversationTurn> _turns = <ConversationTurn>[];

  bool get initialized => _initialized;
  bool get hasApiKey => _apiKey.isNotEmpty;
  bool get rememberKey => _rememberKey;
  bool get audioMuted => _audioMuted;
  bool get isListening => _phase == ConversationPhase.listening;
  bool get isBusy =>
      _phase == ConversationPhase.connecting ||
      _phase == ConversationPhase.reconnecting;
  ConversationPhase get phase => _phase;
  SpeakerSide get activeSpeaker => _activeSpeaker;
  TranslationLanguage get languageA => _languageA;
  TranslationLanguage get languageB => _languageB;
  TranslationLanguage get activeSourceLanguage =>
      _activeSpeaker == SpeakerSide.a ? _languageA : _languageB;
  TranslationLanguage get activeTargetLanguage =>
      _activeSpeaker == SpeakerSide.a ? _languageB : _languageA;
  String get interimSource => _sourceTranscripts[_activeSpeaker]!.value;
  String get interimTranslation =>
      _translatedTranscripts[_activeSpeaker]!.value;
  String? get errorMessage => _errorMessage;
  List<ConversationTurn> get turns =>
      List<ConversationTurn>.unmodifiable(_turns);

  Future<void> initialize() async {
    final String? stored = await _keyStore.read();
    if (_disposed) {
      return;
    }
    if (stored != null && stored.trim().isNotEmpty) {
      _apiKey = stored.trim();
      _rememberKey = true;
      _phase = ConversationPhase.idle;
    } else {
      _phase = ConversationPhase.needsKey;
    }
    _initialized = true;
    notifyListeners();
  }

  Future<bool> validateAndSaveApiKey({
    required String candidate,
    required bool remember,
  }) async {
    final String key = candidate.trim().isEmpty ? _apiKey : candidate.trim();
    if (key.isEmpty) {
      _errorMessage = '请输入 Gemini API Key';
      _phase = ConversationPhase.needsKey;
      notifyListeners();
      return false;
    }
    await stopConversation(preserveError: true);
    _phase = ConversationPhase.connecting;
    _errorMessage = null;
    notifyListeners();

    final LiveTranslationSession probe = _sessionFactory(
      apiKey: key,
      targetLanguageCode: _languageB.code,
    );
    String? probeFailure;
    final StreamSubscription<LiveEvent> subscription = probe.events.listen((
      LiveEvent event,
    ) {
      if (event case LiveSessionFailure(:final String userMessage)) {
        probeFailure = userMessage;
      }
    });
    try {
      await probe.connect();
      if (probeFailure != null) {
        throw StateError('Probe rejected');
      }
      _apiKey = key;
      _rememberKey = remember;
      if (remember) {
        await _keyStore.write(key);
      } else {
        await _keyStore.delete();
      }
      _phase = ConversationPhase.idle;
      _errorMessage = null;
      notifyListeners();
      return true;
    } catch (_) {
      _phase = ConversationPhase.needsKey;
      _errorMessage = probeFailure ?? '验证失败，请检查 Key、模型权限与网络';
      notifyListeners();
      return false;
    } finally {
      await subscription.cancel();
      await probe.close();
    }
  }

  Future<void> removeApiKey() async {
    await stopConversation();
    await _keyStore.delete();
    _apiKey = '';
    _rememberKey = false;
    _phase = ConversationPhase.needsKey;
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> startConversation() async {
    if (!hasApiKey || isBusy || isListening) {
      return;
    }
    _phase = ConversationPhase.connecting;
    _errorMessage = null;
    notifyListeners();
    try {
      if (!await _audioCapture.hasPermission()) {
        _phase = ConversationPhase.permissionDenied;
        _errorMessage = '需要麦克风权限才能进行语音翻译';
        notifyListeners();
        return;
      }
      await _playback.configure();
      await _ensureSession(_activeSpeaker);
      final Stream<Uint8List> stream = await _audioCapture.start();
      _captureSubscription = stream.listen(
        _routeMicrophoneChunk,
        onError: (Object error, StackTrace stackTrace) {
          _phase = ConversationPhase.failed;
          _errorMessage = '麦克风采集失败，请停止后重试';
          notifyListeners();
        },
        cancelOnError: false,
      );
      _phase = ConversationPhase.listening;
      notifyListeners();
      final SpeakerSide standby = _otherSide(_activeSpeaker);
      unawaited(_ensureSession(standby).catchError((Object _) {}));
    } catch (_) {
      _phase = ConversationPhase.failed;
      _errorMessage ??= '无法启动翻译，请检查网络和 API Key';
      notifyListeners();
      await _audioCapture.stop();
    }
  }

  Future<void> _ensureSession(SpeakerSide side) async {
    LiveTranslationSession? session = _sessions[side];
    if (session == null) {
      final TranslationLanguage target = side == SpeakerSide.a
          ? _languageB
          : _languageA;
      session = _sessionFactory(
        apiKey: _apiKey,
        targetLanguageCode: target.code,
      );
      _sessions[side] = session;
      _sessionSubscriptions[side] = session.events.listen(
        (LiveEvent event) => _handleLiveEvent(side, event),
      );
    }
    if (!session.isReady) {
      await session.connect();
    }
  }

  void _routeMicrophoneChunk(Uint8List chunk) {
    if (!isListening ||
        _monotonicClock.elapsedMicroseconds < _captureBlockedUntilMicros) {
      return;
    }
    _sessions[_activeSpeaker]?.sendAudio(chunk);
  }

  void _handleLiveEvent(SpeakerSide side, LiveEvent event) {
    if (_disposed) {
      return;
    }
    switch (event) {
      case LiveInputTranscript(:final String text):
        _sourceTranscripts[side]!.add(text);
        if (side == _activeSpeaker) {
          notifyListeners();
        }
      case LiveOutputTranscript(:final String text):
        _translatedTranscripts[side]!.add(text);
        if (side == _activeSpeaker) {
          notifyListeners();
        }
      case LiveAudioChunk(:final Uint8List bytes):
        if (side == _activeSpeaker && !_audioMuted) {
          _queuePlayback(bytes);
        }
      case LiveTurnComplete():
        _commitTurn(side);
      case LiveInterrupted():
        if (side == _activeSpeaker) {
          _playbackChain = _playbackChain.then((_) => _playback.flush());
        }
      case LivePhaseChanged(:final LiveSessionPhase phase):
        if (side != _activeSpeaker) {
          return;
        }
        if (phase == LiveSessionPhase.reconnecting) {
          _phase = ConversationPhase.reconnecting;
        } else if (phase == LiveSessionPhase.ready &&
            _captureSubscription != null) {
          _phase = ConversationPhase.listening;
          _errorMessage = null;
        }
        notifyListeners();
      case LiveSessionFailure(
        :final String userMessage,
        :final bool authenticationFailure,
      ):
        if (side == _activeSpeaker) {
          _errorMessage = userMessage;
          _phase = authenticationFailure
              ? ConversationPhase.failed
              : ConversationPhase.reconnecting;
          notifyListeners();
        }
      case LiveResumptionHandle() || LiveGoAway():
        break;
    }
  }

  void _queuePlayback(Uint8List bytes) {
    final int durationMicros =
        bytes.length *
        Duration.microsecondsPerSecond ~/
        (outputSampleRateHz * bytesPerSample);
    _captureBlockedUntilMicros = math.max(
      _captureBlockedUntilMicros,
      _monotonicClock.elapsedMicroseconds + durationMicros + 80000,
    );
    _playbackChain = _playbackChain.then((_) => _playback.enqueue(bytes));
  }

  void _commitTurn(SpeakerSide side) {
    final TranscriptAccumulator source = _sourceTranscripts[side]!;
    final TranscriptAccumulator translated = _translatedTranscripts[side]!;
    if (source.isEmpty && translated.isEmpty) {
      return;
    }
    final TranslationLanguage sourceLanguage = side == SpeakerSide.a
        ? _languageA
        : _languageB;
    final TranslationLanguage targetLanguage = side == SpeakerSide.a
        ? _languageB
        : _languageA;
    _turns.add(
      ConversationTurn(
        id: ++_turnId,
        speaker: side,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        sourceText: source.value,
        translatedText: translated.value,
        createdAt: DateTime.now(),
      ),
    );
    source.clear();
    translated.clear();
    notifyListeners();
  }

  Future<void> selectSpeaker(SpeakerSide side) async {
    if (side == _activeSpeaker) {
      return;
    }
    _commitTurn(_activeSpeaker);
    _activeSpeaker = side;
    _errorMessage = null;
    if (_captureSubscription != null) {
      _phase = ConversationPhase.connecting;
      notifyListeners();
      try {
        await _ensureSession(side);
        _phase = ConversationPhase.listening;
      } catch (_) {
        _phase = ConversationPhase.failed;
        _errorMessage = '切换方向失败，请检查连接后重试';
      }
    }
    notifyListeners();
  }

  Future<void> setLanguage(
    SpeakerSide side,
    TranslationLanguage language,
  ) async {
    await stopConversation();
    if (side == SpeakerSide.a) {
      if (language.code == _languageB.code) {
        _languageB = _languageA;
      }
      _languageA = language;
    } else {
      if (language.code == _languageA.code) {
        _languageA = _languageB;
      }
      _languageB = language;
    }
    notifyListeners();
  }

  Future<void> swapLanguages() async {
    await stopConversation();
    final TranslationLanguage oldA = _languageA;
    _languageA = _languageB;
    _languageB = oldA;
    notifyListeners();
  }

  void toggleAudioMuted() {
    _audioMuted = !_audioMuted;
    if (_audioMuted) {
      _playbackChain = _playbackChain.then((_) => _playback.flush());
    }
    notifyListeners();
  }

  void clearHistory() {
    _turns.clear();
    for (final TranscriptAccumulator value in _sourceTranscripts.values) {
      value.clear();
    }
    for (final TranscriptAccumulator value in _translatedTranscripts.values) {
      value.clear();
    }
    notifyListeners();
  }

  Future<void> stopConversation({bool preserveError = false}) async {
    _commitTurn(_activeSpeaker);
    await _captureSubscription?.cancel();
    _captureSubscription = null;
    await _audioCapture.stop();
    for (final StreamSubscription<LiveEvent> subscription
        in _sessionSubscriptions.values) {
      await subscription.cancel();
    }
    _sessionSubscriptions.clear();
    for (final LiveTranslationSession session in _sessions.values) {
      await session.close();
    }
    _sessions.clear();
    await _playback.flush();
    if (!preserveError) {
      _errorMessage = null;
    }
    if (!_disposed) {
      _phase = hasApiKey ? ConversationPhase.idle : ConversationPhase.needsKey;
      notifyListeners();
    }
  }

  static SpeakerSide _otherSide(SpeakerSide side) =>
      side == SpeakerSide.a ? SpeakerSide.b : SpeakerSide.a;

  @override
  void dispose() {
    _disposed = true;
    unawaited(_disposeResources());
    super.dispose();
  }

  Future<void> _disposeResources() async {
    await _captureSubscription?.cancel();
    await _audioCapture.dispose();
    for (final StreamSubscription<LiveEvent> subscription
        in _sessionSubscriptions.values) {
      await subscription.cancel();
    }
    for (final LiveTranslationSession session in _sessions.values) {
      await session.close();
    }
    await _playback.dispose();
  }
}
