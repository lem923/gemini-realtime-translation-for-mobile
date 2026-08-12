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
import 'conversation_diagnostics.dart';
import 'conversation_models.dart';

class ConversationController extends ChangeNotifier {
  ConversationController({
    ApiKeyStore? keyStore,
    AudioCaptureGateway? audioCapture,
    PcmPlaybackGateway? playback,
    LiveSessionFactory? sessionFactory,
    int Function()? monotonicMicros,
  }) : _keyStore = keyStore ?? SecureApiKeyStore(),
       _audioCapture = audioCapture ?? RecordAudioCaptureGateway(),
       _playback = playback ?? PlatformPcmPlaybackGateway(),
       _monotonicMicros = monotonicMicros ?? _createMonotonicClock(),
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
  final int Function() _monotonicMicros;
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
  Future<void>? _stopOperation;
  String _apiKey = '';
  bool _rememberKey = false;
  bool _initialized = false;
  bool _audioMuted = false;
  bool _disposed = false;
  bool _playbackFailureReported = false;
  int _captureBlockedUntilMicros = 0;
  int _scheduledPlaybackEndMicros = 0;
  int _conversationGeneration = 0;
  int _turnId = 0;
  int? _diagnosticStartedMicros;
  int? _diagnosticStoppedMicros;
  int? _firstSourceTextMilliseconds;
  int? _firstTranslatedTextMilliseconds;
  int? _firstTranslatedAudioMilliseconds;
  int _microphoneChunksSent = 0;
  int _microphoneChunksSuppressed = 0;
  int _outputAudioChunks = 0;
  int _outputAudioBytes = 0;
  int _diagnosticCompletedTurns = 0;
  int _directionSwitches = 0;
  int _reconnectEvents = 0;
  int _sessionFailures = 0;
  int _playbackFailures = 0;
  int _maximumScheduledPlaybackMicros = 0;
  String? _errorMessage;
  ConversationPhase _phase = ConversationPhase.needsKey;
  SpeakerSide _activeSpeaker = SpeakerSide.a;
  TranslationLanguage _languageA = languageByCode('zh-Hans');
  TranslationLanguage _languageB = languageByCode('en');
  final List<ConversationTurn> _turns = <ConversationTurn>[];

  static const int maxHistoryTurns = 200;
  static const int _playbackEchoGuardMicros = 80000;

  bool get initialized => _initialized;
  bool get hasApiKey => _apiKey.isNotEmpty;
  bool get rememberKey => _rememberKey;
  bool get audioMuted => _audioMuted;
  bool get isListening => _phase == ConversationPhase.listening;
  bool get isBusy =>
      _phase == ConversationPhase.connecting ||
      _phase == ConversationPhase.reconnecting ||
      _stopOperation != null;
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
    _resetDiagnostics(_monotonicMicros());
    final int generation = ++_conversationGeneration;
    notifyListeners();
    try {
      if (!await _audioCapture.hasPermission()) {
        if (!_isCurrentConversation(generation)) {
          return;
        }
        _phase = ConversationPhase.permissionDenied;
        _errorMessage = '需要麦克风权限才能进行语音翻译';
        notifyListeners();
        return;
      }
      if (!_isCurrentConversation(generation)) {
        return;
      }
      await _waitForPlayback();
      await _playback.configure();
      _resetPlaybackTimeline();
      _playbackFailureReported = false;
      if (!_isCurrentConversation(generation)) {
        await _flushPlayback();
        return;
      }
      await _ensureSession(_activeSpeaker);
      if (!_isCurrentConversation(generation)) {
        return;
      }
      final Stream<Uint8List> stream = await _audioCapture.start();
      if (!_isCurrentConversation(generation)) {
        await _audioCapture.stop();
        return;
      }
      _captureSubscription = stream.listen(
        _routeMicrophoneChunk,
        onError: (Object error, StackTrace stackTrace) {
          _terminateConversation('麦克风采集失败，请重试');
        },
        cancelOnError: false,
      );
      _phase = ConversationPhase.listening;
      notifyListeners();
      final SpeakerSide standby = _otherSide(_activeSpeaker);
      unawaited(_ensureSession(standby).catchError((Object _) {}));
    } catch (_) {
      if (!_isCurrentConversation(generation)) {
        return;
      }
      final String message = _errorMessage ?? '无法启动翻译，请检查网络和 API Key';
      _terminateConversation(message);
      await _stopOperation;
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
    if (!isListening) {
      return;
    }
    if (_monotonicMicros() < _captureBlockedUntilMicros) {
      _microphoneChunksSuppressed += 1;
      return;
    }
    final LiveTranslationSession? session = _sessions[_activeSpeaker];
    if (session?.isReady == true) {
      _microphoneChunksSent += 1;
      session!.sendAudio(chunk);
    }
  }

  void _handleLiveEvent(SpeakerSide side, LiveEvent event) {
    if (_disposed) {
      return;
    }
    switch (event) {
      case LiveInputTranscript(:final String text):
        if (side == _activeSpeaker) {
          _firstSourceTextMilliseconds ??= _elapsedDiagnosticMilliseconds();
        }
        _sourceTranscripts[side]!.add(text);
        if (side == _activeSpeaker) {
          notifyListeners();
        }
      case LiveOutputTranscript(:final String text):
        if (side == _activeSpeaker) {
          _firstTranslatedTextMilliseconds ??= _elapsedDiagnosticMilliseconds();
        }
        _translatedTranscripts[side]!.add(text);
        if (side == _activeSpeaker) {
          notifyListeners();
        }
      case LiveAudioChunk(:final Uint8List bytes):
        if (side == _activeSpeaker) {
          _firstTranslatedAudioMilliseconds ??=
              _elapsedDiagnosticMilliseconds();
          _outputAudioChunks += 1;
          _outputAudioBytes += bytes.length;
          if (!_audioMuted) {
            _queuePlayback(bytes);
          }
        }
      case LiveTurnComplete():
        _commitTurn(side);
      case LiveInterrupted():
        if (side == _activeSpeaker) {
          unawaited(_flushPlayback());
        }
      case LivePhaseChanged(:final LiveSessionPhase phase):
        if (side != _activeSpeaker) {
          return;
        }
        if (phase == LiveSessionPhase.reconnecting) {
          _reconnectEvents += 1;
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
        :final bool retryable,
      ):
        if (side == _activeSpeaker) {
          _sessionFailures += 1;
          if (authenticationFailure || !retryable) {
            _terminateConversation(userMessage);
          } else {
            _errorMessage = userMessage;
            _phase = ConversationPhase.reconnecting;
            notifyListeners();
          }
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
    final int now = _monotonicMicros();
    final int playbackStart = math.max(now, _scheduledPlaybackEndMicros);
    _scheduledPlaybackEndMicros = playbackStart + durationMicros;
    _maximumScheduledPlaybackMicros = math.max(
      _maximumScheduledPlaybackMicros,
      _scheduledPlaybackEndMicros - now,
    );
    _captureBlockedUntilMicros =
        _scheduledPlaybackEndMicros + _playbackEchoGuardMicros;
    _appendPlayback(() => _playback.enqueue(bytes));
  }

  void _appendPlayback(Future<void> Function() operation) {
    _playbackChain = _playbackChain.then((_) => operation()).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      _handlePlaybackFailure();
    });
  }

  Future<void> _waitForPlayback() => _playbackChain;

  Future<void> _flushPlayback() {
    _resetPlaybackTimeline();
    _appendPlayback(_playback.flush);
    return _playbackChain;
  }

  void _resetPlaybackTimeline() {
    final int now = _monotonicMicros();
    _scheduledPlaybackEndMicros = now;
    _captureBlockedUntilMicros = now;
  }

  void _handlePlaybackFailure() {
    if (_disposed || _playbackFailureReported) {
      return;
    }
    _playbackFailureReported = true;
    _playbackFailures += 1;
    _audioMuted = true;
    _resetPlaybackTimeline();
    _errorMessage = '译音播放失败，文字翻译仍可继续';
    notifyListeners();
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
    if (_turns.length > maxHistoryTurns) {
      _turns.removeRange(0, _turns.length - maxHistoryTurns);
    }
    _diagnosticCompletedTurns += 1;
    source.clear();
    translated.clear();
    notifyListeners();
  }

  Future<void> selectSpeaker(SpeakerSide side) async {
    if (side == _activeSpeaker) {
      return;
    }
    if (_diagnosticStartedMicros != null && _diagnosticStoppedMicros == null) {
      _directionSwitches += 1;
    }
    _commitTurn(_activeSpeaker);
    _activeSpeaker = side;
    _errorMessage = null;
    if (_captureSubscription != null) {
      final int generation = _conversationGeneration;
      _phase = ConversationPhase.connecting;
      notifyListeners();
      try {
        await _ensureSession(side);
        if (_isCurrentConversation(generation) &&
            side == _activeSpeaker &&
            _captureSubscription != null) {
          _phase = ConversationPhase.listening;
        }
      } catch (_) {
        if (_isCurrentConversation(generation) && side == _activeSpeaker) {
          _terminateConversation('切换方向失败，请检查连接后重试');
        }
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
      unawaited(_flushPlayback());
    } else {
      _playbackFailureReported = false;
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

  Future<void> stopConversation({bool preserveError = false}) {
    return _stopConversationWithOutcome(preserveError: preserveError);
  }

  Future<void> _stopConversationWithOutcome({
    required bool preserveError,
    ConversationPhase? finalPhase,
    String? finalError,
  }) {
    final Future<void>? inFlight = _stopOperation;
    if (inFlight != null) {
      return inFlight;
    }
    late final Future<void> operation;
    operation =
        _stopConversationInternal(
          preserveError: preserveError,
          finalPhase: finalPhase,
          finalError: finalError,
        ).whenComplete(() {
          if (identical(_stopOperation, operation)) {
            _stopOperation = null;
            if (!_disposed) {
              notifyListeners();
            }
          }
        });
    _stopOperation = operation;
    return operation;
  }

  Future<void> _stopConversationInternal({
    required bool preserveError,
    ConversationPhase? finalPhase,
    String? finalError,
  }) async {
    _conversationGeneration += 1;
    if (_diagnosticStartedMicros != null) {
      _diagnosticStoppedMicros ??= _monotonicMicros();
    }
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
    await _flushPlayback();
    if (!preserveError) {
      _errorMessage = null;
    } else if (finalError != null) {
      _errorMessage = finalError;
    }
    if (!_disposed) {
      _phase =
          finalPhase ??
          (hasApiKey ? ConversationPhase.idle : ConversationPhase.needsKey);
      notifyListeners();
    }
  }

  void _terminateConversation(String message) {
    if (_disposed) {
      return;
    }
    _phase = ConversationPhase.failed;
    _errorMessage = message;
    if (_diagnosticStartedMicros != null) {
      _diagnosticStoppedMicros ??= _monotonicMicros();
    }
    notifyListeners();
    unawaited(
      _stopConversationWithOutcome(
        preserveError: true,
        finalPhase: ConversationPhase.failed,
        finalError: message,
      ),
    );
  }

  static SpeakerSide _otherSide(SpeakerSide side) =>
      side == SpeakerSide.a ? SpeakerSide.b : SpeakerSide.a;

  bool _isCurrentConversation(int generation) =>
      !_disposed && generation == _conversationGeneration;

  static int Function() _createMonotonicClock() {
    final Stopwatch stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsedMicroseconds;
  }

  Future<ConversationDiagnostics> collectDiagnostics() async {
    PcmPlaybackMetrics playbackMetrics = const PcmPlaybackMetrics.empty();
    bool playbackMetricsAvailable = true;
    try {
      playbackMetrics = await _playback.metrics();
    } catch (_) {
      playbackMetricsAvailable = false;
    }
    final int? startedMicros = _diagnosticStartedMicros;
    final int durationMilliseconds = startedMicros == null
        ? 0
        : math.max(
                0,
                (_diagnosticStoppedMicros ?? _monotonicMicros()) -
                    startedMicros,
              ) ~/
              Duration.microsecondsPerMillisecond;
    return ConversationDiagnostics(
      phase: _phase,
      sessionDurationMilliseconds: durationMilliseconds,
      microphoneChunksSent: _microphoneChunksSent,
      microphoneChunksSuppressed: _microphoneChunksSuppressed,
      outputAudioChunks: _outputAudioChunks,
      outputAudioBytes: _outputAudioBytes,
      completedTurns: _diagnosticCompletedTurns,
      directionSwitches: _directionSwitches,
      reconnectEvents: _reconnectEvents,
      sessionFailures: _sessionFailures,
      playbackFailures: _playbackFailures,
      firstSourceTextMilliseconds: _firstSourceTextMilliseconds,
      firstTranslatedTextMilliseconds: _firstTranslatedTextMilliseconds,
      firstTranslatedAudioMilliseconds: _firstTranslatedAudioMilliseconds,
      maximumScheduledPlaybackMilliseconds:
          _maximumScheduledPlaybackMicros ~/
          Duration.microsecondsPerMillisecond,
      playbackMetrics: playbackMetrics,
      playbackMetricsAvailable: playbackMetricsAvailable,
    );
  }

  void _resetDiagnostics(int startedMicros) {
    _diagnosticStartedMicros = startedMicros;
    _diagnosticStoppedMicros = null;
    _firstSourceTextMilliseconds = null;
    _firstTranslatedTextMilliseconds = null;
    _firstTranslatedAudioMilliseconds = null;
    _microphoneChunksSent = 0;
    _microphoneChunksSuppressed = 0;
    _outputAudioChunks = 0;
    _outputAudioBytes = 0;
    _diagnosticCompletedTurns = 0;
    _directionSwitches = 0;
    _reconnectEvents = 0;
    _sessionFailures = 0;
    _playbackFailures = 0;
    _maximumScheduledPlaybackMicros = 0;
  }

  int _elapsedDiagnosticMilliseconds() {
    final int? startedMicros = _diagnosticStartedMicros;
    if (startedMicros == null) {
      return 0;
    }
    return math.max(0, _monotonicMicros() - startedMicros) ~/
        Duration.microsecondsPerMillisecond;
  }

  @override
  void dispose() {
    _disposed = true;
    _conversationGeneration += 1;
    unawaited(_disposeResources());
    super.dispose();
  }

  Future<void> _disposeResources() async {
    await _stopOperation;
    await _captureSubscription?.cancel();
    await _audioCapture.dispose();
    for (final StreamSubscription<LiveEvent> subscription
        in _sessionSubscriptions.values) {
      await subscription.cancel();
    }
    for (final LiveTranslationSession session in _sessions.values) {
      await session.close();
    }
    await _flushPlayback();
    await _playback.dispose();
  }
}
