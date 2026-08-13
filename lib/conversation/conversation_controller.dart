import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../audio/audio_capture_gateway.dart';
import '../audio/audio_constants.dart';
import '../audio/pcm_playback_gateway.dart';
import '../live_translate/live_event.dart';
import '../live_translate/live_translation_session.dart';
import '../permissions/microphone_permission_gateway.dart';
import '../preferences/language_pair_store.dart';
import '../security/api_key_store.dart';
import '../shared/translation_language.dart';
import 'conversation_diagnostics.dart';
import 'conversation_models.dart';

class ConversationController extends ChangeNotifier {
  ConversationController({
    ApiKeyStore? keyStore,
    AudioCaptureGateway? audioCapture,
    PcmPlaybackGateway? playback,
    LanguagePairStore? languagePairStore,
    MicrophonePermissionGateway? permissionGateway,
    LiveSessionFactory? sessionFactory,
    int Function()? monotonicMicros,
  }) : _keyStore = keyStore ?? SecureApiKeyStore(),
       _audioCapture = audioCapture ?? RecordAudioCaptureGateway(),
       _playback = playback ?? PlatformPcmPlaybackGateway(),
       _languagePairStore =
           languagePairStore ?? const DisabledLanguagePairStore(),
       _permissionGateway =
           permissionGateway ?? const DisabledMicrophonePermissionGateway(),
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
  final LanguagePairStore _languagePairStore;
  final MicrophonePermissionGateway _permissionGateway;
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
  StreamSubscription<PcmPlaybackEvent>? _playbackEventSubscription;
  StreamSubscription<MicrophonePermissionStatus>? _permissionSubscription;
  Future<void> _playbackChain = Future<void>.value();
  Future<void>? _stopOperation;
  Future<void>? _replayOperation;
  String _apiKey = '';
  bool _rememberKey = false;
  bool _initialized = false;
  bool _audioMuted = false;
  bool _disposed = false;
  bool _playbackFailureReported = false;
  bool _playbackConfigured = false;
  bool _microphonePermissionGrantedOnce = false;
  AudioOutputRoute _activeOutputRoute = AudioOutputRoute.unknown;
  int _captureBlockedUntilMicros = 0;
  int _scheduledPlaybackEndMicros = 0;
  int _conversationGeneration = 0;
  int _replayGeneration = 0;
  int _turnId = 0;
  int? _replayingTurnId;
  int? _diagnosticStartedMicros;
  int? _diagnosticStoppedMicros;
  int? _firstMicrophoneSentMicros;
  int? _listeningReadyMilliseconds;
  int? _firstMicrophoneSentMilliseconds;
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
  int _audioInterruptions = 0;
  int _geminiPromptTokens = 0;
  int _geminiResponseTokens = 0;
  int _geminiTotalTokens = 0;
  bool _geminiUsageAvailable = false;
  int _maximumScheduledPlaybackMicros = 0;
  String? _errorMessage;
  ConversationPhase _phase = ConversationPhase.needsKey;
  SpeakerSide _activeSpeaker = SpeakerSide.a;
  TranslationLanguage _languageA = languageByCode('zh-Hans');
  TranslationLanguage _languageB = languageByCode('en');
  final List<ConversationTurn> _turns = <ConversationTurn>[];
  final Map<SpeakerSide, BytesBuilder> _turnAudio = <SpeakerSide, BytesBuilder>{
    SpeakerSide.a: BytesBuilder(copy: true),
    SpeakerSide.b: BytesBuilder(copy: true),
  };
  final Map<SpeakerSide, bool> _turnAudioOverflow = <SpeakerSide, bool>{
    SpeakerSide.a: false,
    SpeakerSide.b: false,
  };
  final Map<int, Uint8List> _replayAudio = <int, Uint8List>{};
  int _replayAudioBytes = 0;

  static const int maxHistoryTurns = 200;
  static const int maxReplayTurnBytes =
      outputSampleRateHz * bytesPerSample * 30;
  static const int maxReplayCacheBytes = 8 * 1024 * 1024;
  static const int _replayChunkBytes =
      outputSampleRateHz * bytesPerSample ~/ 10;

  bool get initialized => _initialized;
  bool get hasApiKey => _apiKey.isNotEmpty;
  bool get rememberKey => _rememberKey;
  bool get audioMuted => _audioMuted;
  int? get replayingTurnId => _replayingTurnId;
  bool get isListening =>
      _phase == ConversationPhase.listening ||
      _phase == ConversationPhase.translating;
  bool get canStopConversation =>
      _stopOperation == null &&
      (isListening ||
          _phase == ConversationPhase.connecting ||
          _phase == ConversationPhase.reconnecting ||
          (_phase == ConversationPhase.offline &&
              _captureSubscription != null));
  bool get isBusy =>
      _phase == ConversationPhase.connecting ||
      _phase == ConversationPhase.reconnecting ||
      (_phase == ConversationPhase.offline && _captureSubscription != null) ||
      _replayingTurnId != null ||
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
  bool get hasInterimTranscript =>
      interimSource.isNotEmpty || interimTranslation.isNotEmpty;
  ConversationTurn? get latestActiveTurn {
    final TranslationLanguage expectedSource = activeSourceLanguage;
    final TranslationLanguage expectedTarget = activeTargetLanguage;
    for (final ConversationTurn turn in _turns.reversed) {
      if (turn.speaker == _activeSpeaker &&
          turn.sourceLanguage.code == expectedSource.code &&
          turn.targetLanguage.code == expectedTarget.code) {
        return turn;
      }
    }
    return null;
  }

  String? get errorMessage => _errorMessage;
  List<ConversationTurn> get turns =>
      List<ConversationTurn>.unmodifiable(_turns);

  bool hasReplayAudio(int turnId) => _replayAudio.containsKey(turnId);

  Future<void> initialize() async {
    _playbackEventSubscription ??= _playback.events.listen(
      _handlePlaybackEvent,
      onError: (Object _) {},
    );
    _permissionSubscription ??= _permissionGateway.changes.listen(
      _handleMicrophonePermissionChanged,
      onError: (Object _) {},
    );
    StoredLanguagePair? storedPair;
    try {
      storedPair = await _languagePairStore.read();
    } catch (_) {
      // A corrupt/unavailable non-sensitive preference must never prevent the
      // translator from starting with its safe default pair.
    }
    final TranslationLanguage? storedA = storedPair == null
        ? null
        : tryLanguageByCode(storedPair.languageA);
    final TranslationLanguage? storedB = storedPair == null
        ? null
        : tryLanguageByCode(storedPair.languageB);
    if (storedA != null && storedB != null && storedA.code != storedB.code) {
      _languageA = storedA;
      _languageB = storedB;
    }
    String? stored;
    try {
      stored = await _keyStore.read();
    } catch (_) {
      _errorMessage = '无法读取已保存的 API Key，请重新输入';
    }
    if (_disposed) {
      return;
    }
    if (stored != null && stored.trim().isNotEmpty) {
      _apiKey = stored.trim();
      _rememberKey = true;
      MicrophonePermissionStatus? currentPermission;
      try {
        currentPermission = await _permissionGateway.currentStatus();
      } catch (_) {
        // Permission status is advisory at startup. The explicit start action
        // remains responsible for requesting access when status is unknown.
      }
      _microphonePermissionGrantedOnce =
          currentPermission == MicrophonePermissionStatus.granted;
      if (currentPermission == MicrophonePermissionStatus.denied) {
        _phase = ConversationPhase.permissionDenied;
        _errorMessage = '需要麦克风权限才能进行语音翻译';
      } else {
        _phase = ConversationPhase.idle;
      }
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
      final bool permissionGranted = await _audioCapture.hasPermission();
      try {
        await _permissionGateway.recordRequestResult(
          granted: permissionGranted,
        );
      } catch (_) {
        // The capture result remains authoritative. Persisting permission
        // history only improves the next cold-start recovery state.
      }
      if (!permissionGranted) {
        if (!_isCurrentConversation(generation)) {
          return;
        }
        _phase = ConversationPhase.permissionDenied;
        _errorMessage = '需要麦克风权限才能进行语音翻译';
        notifyListeners();
        return;
      }
      _microphonePermissionGrantedOnce = true;
      if (!_isCurrentConversation(generation)) {
        return;
      }
      await _ensurePlaybackConfigured();
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
      _listeningReadyMilliseconds ??= _elapsedDiagnosticMilliseconds();
      notifyListeners();
      final SpeakerSide standby = _otherSide(_activeSpeaker);
      unawaited(_ensureSession(standby).catchError((Object _) {}));
    } catch (error) {
      if (!_isCurrentConversation(generation)) {
        return;
      }
      final Future<void>? stopping = _stopOperation;
      if (stopping != null) {
        await stopping;
        return;
      }
      final String message =
          _errorMessage ??
          (error is AudioCaptureStartupException
              ? '麦克风无法开始采集，请检查麦克风后重试'
              : '无法启动翻译，请检查网络和 API Key');
      final ConversationPhase failurePhase = switch (_phase) {
        ConversationPhase.offline => ConversationPhase.offline,
        ConversationPhase.rateLimited => ConversationPhase.rateLimited,
        _ => ConversationPhase.failed,
      };
      _terminateConversation(message, phase: failurePhase);
      await _stopOperation;
    }
  }

  void _handleMicrophonePermissionChanged(MicrophonePermissionStatus status) {
    if (_disposed) {
      return;
    }
    if (status == MicrophonePermissionStatus.granted) {
      _microphonePermissionGrantedOnce = true;
      if (_phase == ConversationPhase.permissionDenied &&
          _stopOperation == null) {
        _phase = hasApiKey
            ? ConversationPhase.idle
            : ConversationPhase.needsKey;
        _errorMessage = null;
        notifyListeners();
      }
      return;
    }
    if (status == MicrophonePermissionStatus.notDetermined &&
        !_microphonePermissionGrantedOnce) {
      if (_phase == ConversationPhase.permissionDenied &&
          _stopOperation == null) {
        _phase = hasApiKey
            ? ConversationPhase.idle
            : ConversationPhase.needsKey;
        _errorMessage = null;
        notifyListeners();
      }
      return;
    }
    if (!_microphonePermissionGrantedOnce && _captureSubscription == null) {
      if (_phase != ConversationPhase.needsKey &&
          _phase != ConversationPhase.permissionDenied) {
        _phase = ConversationPhase.permissionDenied;
        _errorMessage = '需要麦克风权限才能进行语音翻译';
        notifyListeners();
      }
      return;
    }
    _microphonePermissionGrantedOnce = false;
    const String message = '麦克风权限已被撤销，翻译已停止';
    if (canStopConversation || _captureSubscription != null) {
      _terminateConversation(
        message,
        phase: ConversationPhase.permissionDenied,
      );
    } else if (_phase != ConversationPhase.needsKey) {
      _phase = ConversationPhase.permissionDenied;
      _errorMessage = message;
      notifyListeners();
    }
  }

  Future<void> refreshMicrophonePermission() async {
    if (_disposed ||
        (!_microphonePermissionGrantedOnce &&
            _phase != ConversationPhase.permissionDenied)) {
      return;
    }
    try {
      final MicrophonePermissionStatus? status = await _permissionGateway
          .currentStatus();
      if (status != null) {
        _handleMicrophonePermissionChanged(status);
      }
    } catch (_) {
      // The native permission event remains authoritative. A lifecycle probe
      // failure must not stop an otherwise healthy conversation.
    }
  }

  Future<void> openMicrophoneSettings() async {
    try {
      await _permissionGateway.openAppSettings();
    } catch (_) {
      _errorMessage = '无法打开系统设置，请手动为本应用开启麦克风权限';
      notifyListeners();
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
      final int now = _monotonicMicros();
      _firstMicrophoneSentMicros ??= now;
      _firstMicrophoneSentMilliseconds ??= _elapsedDiagnosticMillisecondsAt(
        now,
      );
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
        if (side != _activeSpeaker) return;
        _firstSourceTextMilliseconds ??= _elapsedFromFirstSendMilliseconds();
        _sourceTranscripts[side]!.add(text);
        notifyListeners();
      case LiveOutputTranscript(:final String text):
        if (side != _activeSpeaker) return;
        _markTranslating();
        _firstTranslatedTextMilliseconds ??=
            _elapsedFromFirstSendMilliseconds();
        _translatedTranscripts[side]!.add(text);
        notifyListeners();
      case LiveAudioChunk(:final Uint8List bytes):
        if (side == _activeSpeaker) {
          final bool phaseChanged = _markTranslating();
          _cacheTurnAudio(side, bytes);
          _firstTranslatedAudioMilliseconds ??=
              _elapsedFromFirstSendMilliseconds();
          _outputAudioChunks += 1;
          _outputAudioBytes += bytes.length;
          if (!_audioMuted) {
            if (_cancelReplayState()) {
              // Fresh translated speech has priority over an old replay. The
              // flush and live chunk share the same serialized playback chain,
              // so replay audio cannot leak into the new response.
              unawaited(_flushPlayback());
            }
            _queuePlayback(bytes);
          }
          if (phaseChanged) {
            notifyListeners();
          }
        }
      case LiveTurnComplete():
        if (side != _activeSpeaker) return;
        _commitTurn(side);
        if (_captureSubscription != null &&
            _phase == ConversationPhase.translating) {
          _phase = ConversationPhase.listening;
          notifyListeners();
        }
      case LiveInterrupted():
        if (side == _activeSpeaker) {
          _discardTurnAudio(side);
          if (_replayingTurnId != null || _replayOperation != null) {
            unawaited(stopReplay());
          } else {
            unawaited(_flushPlayback());
          }
          if (_captureSubscription != null) {
            _phase = ConversationPhase.listening;
            notifyListeners();
          }
        }
      case LiveUsageMetadata():
        _recordUsage(event);
      case LivePhaseChanged(:final LiveSessionPhase phase):
        if (side != _activeSpeaker) {
          return;
        }
        if (phase == LiveSessionPhase.reconnecting) {
          _reconnectEvents += 1;
          if (_phase != ConversationPhase.offline) {
            _phase = ConversationPhase.reconnecting;
          }
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
        :final LiveFailureKind kind,
      ):
        if (side == _activeSpeaker) {
          _sessionFailures += 1;
          if (authenticationFailure || !retryable) {
            final ConversationPhase terminalPhase = switch (kind) {
              LiveFailureKind.rateLimited => ConversationPhase.rateLimited,
              LiveFailureKind.offline => ConversationPhase.offline,
              _ => ConversationPhase.failed,
            };
            _terminateConversation(userMessage, phase: terminalPhase);
          } else {
            _errorMessage = userMessage;
            _phase = kind == LiveFailureKind.offline
                ? ConversationPhase.offline
                : ConversationPhase.reconnecting;
            notifyListeners();
          }
        }
      case LiveResumptionHandle() || LiveGoAway():
        break;
    }
  }

  bool _markTranslating() {
    if (_captureSubscription != null && _phase == ConversationPhase.listening) {
      _phase = ConversationPhase.translating;
      return true;
    }
    return false;
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
        _scheduledPlaybackEndMicros +
        echoGuardMicrosForRoute(_activeOutputRoute);
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

  Future<void> _ensurePlaybackConfigured() async {
    await _waitForPlayback();
    if (_playbackConfigured) {
      return;
    }
    await _playback.configure();
    _playbackConfigured = true;
    _resetPlaybackTimeline();
  }

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

  void _handlePlaybackEvent(PcmPlaybackEvent event) {
    if (_disposed) {
      return;
    }
    if (event case PcmPlaybackRouteChanged(:final AudioOutputRoute route)) {
      _activeOutputRoute = route;
      if (_scheduledPlaybackEndMicros > _monotonicMicros()) {
        _captureBlockedUntilMicros =
            _scheduledPlaybackEndMicros + echoGuardMicrosForRoute(route);
      }
      return;
    }
    if (event is! PcmPlaybackInterrupted) {
      return;
    }
    if (_replayingTurnId != null) {
      _audioInterruptions += 1;
      _errorMessage = '音频被系统中断，回放已停止';
      unawaited(stopReplay());
      notifyListeners();
      return;
    }
    if (_phase == ConversationPhase.failed) {
      return;
    }
    if (_captureSubscription == null && !isBusy && !isListening) {
      return;
    }
    _audioInterruptions += 1;
    _terminateConversation('音频被系统中断，翻译已停止');
  }

  void _cacheTurnAudio(SpeakerSide side, Uint8List bytes) {
    if (bytes.isEmpty || _turnAudioOverflow[side] == true) {
      return;
    }
    final BytesBuilder builder = _turnAudio[side]!;
    if (builder.length + bytes.length > maxReplayTurnBytes) {
      _discardTurnAudio(side, overflowed: true);
      return;
    }
    builder.add(bytes);
  }

  void _discardTurnAudio(SpeakerSide side, {bool overflowed = false}) {
    _turnAudio[side]!.clear();
    _turnAudioOverflow[side] = overflowed;
  }

  Uint8List? _takeTurnAudio(SpeakerSide side) {
    final BytesBuilder builder = _turnAudio[side]!;
    final bool overflowed = _turnAudioOverflow[side] == true;
    final Uint8List? audio = !overflowed && builder.isNotEmpty
        ? builder.takeBytes()
        : null;
    if (overflowed) {
      builder.clear();
    }
    _turnAudioOverflow[side] = false;
    return audio;
  }

  void _storeReplayAudio(int turnId, Uint8List? audio) {
    if (audio == null || audio.isEmpty) {
      return;
    }
    _replayAudio[turnId] = audio;
    _replayAudioBytes += audio.length;
    while (_replayAudioBytes > maxReplayCacheBytes && _replayAudio.isNotEmpty) {
      final int oldestTurnId = _replayAudio.keys.first;
      _removeReplayAudio(oldestTurnId);
    }
  }

  void _removeReplayAudio(int turnId) {
    final Uint8List? removed = _replayAudio.remove(turnId);
    if (removed != null) {
      _replayAudioBytes = math.max(0, _replayAudioBytes - removed.length);
    }
  }

  void _commitTurn(SpeakerSide side) {
    final TranscriptAccumulator source = _sourceTranscripts[side]!;
    final TranscriptAccumulator translated = _translatedTranscripts[side]!;
    if (source.isEmpty && translated.isEmpty) {
      _discardTurnAudio(side);
      return;
    }
    final TranslationLanguage sourceLanguage = side == SpeakerSide.a
        ? _languageA
        : _languageB;
    final TranslationLanguage targetLanguage = side == SpeakerSide.a
        ? _languageB
        : _languageA;
    final int turnId = ++_turnId;
    _turns.add(
      ConversationTurn(
        id: turnId,
        speaker: side,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        sourceText: source.value,
        translatedText: translated.value,
        createdAt: DateTime.now(),
      ),
    );
    _storeReplayAudio(turnId, _takeTurnAudio(side));
    if (_turns.length > maxHistoryTurns) {
      final List<ConversationTurn> removed = _turns.sublist(
        0,
        _turns.length - maxHistoryTurns,
      );
      for (final ConversationTurn turn in removed) {
        _removeReplayAudio(turn.id);
      }
      _turns.removeRange(0, removed.length);
    }
    _diagnosticCompletedTurns += 1;
    source.clear();
    translated.clear();
    notifyListeners();
  }

  Future<void> selectSpeaker(SpeakerSide side) async {
    if (_replayingTurnId != null || _replayOperation != null) {
      await stopReplay();
    }
    if (side == _activeSpeaker) {
      return;
    }
    if (_diagnosticStartedMicros != null && _diagnosticStoppedMicros == null) {
      _directionSwitches += 1;
    }
    _sessions[_activeSpeaker]?.endAudioStream();
    _commitTurn(_activeSpeaker);
    _activeSpeaker = side;
    _errorMessage = null;
    if (_captureSubscription != null) {
      final int generation = _conversationGeneration;
      _phase = ConversationPhase.connecting;
      notifyListeners();
      try {
        // A manual direction change is a barge-in boundary. Stop any speech
        // translated for the previous speaker before reopening the microphone
        // for the new direction, otherwise stale output can be recaptured.
        await _flushPlayback();
        if (!_isCurrentConversation(generation) ||
            side != _activeSpeaker ||
            _captureSubscription == null) {
          return;
        }
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
    await _persistLanguagePair();
    notifyListeners();
  }

  Future<void> swapLanguages() async {
    await stopConversation();
    final TranslationLanguage oldA = _languageA;
    _languageA = _languageB;
    _languageB = oldA;
    await _persistLanguagePair();
    notifyListeners();
  }

  Future<void> _persistLanguagePair() async {
    try {
      await _languagePairStore.write(
        StoredLanguagePair(
          languageA: _languageA.code,
          languageB: _languageB.code,
        ),
      );
    } catch (_) {
      _errorMessage = '语言已切换，但未能保存为下次默认值';
    }
  }

  void toggleAudioMuted() {
    _audioMuted = !_audioMuted;
    if (_audioMuted) {
      if (_replayingTurnId != null || _replayOperation != null) {
        unawaited(stopReplay());
      } else {
        unawaited(_flushPlayback());
      }
    } else {
      _playbackFailureReported = false;
    }
    notifyListeners();
  }

  void clearHistory() {
    unawaited(stopReplay());
    _turns.clear();
    _replayAudio.clear();
    _replayAudioBytes = 0;
    for (final TranscriptAccumulator value in _sourceTranscripts.values) {
      value.clear();
    }
    for (final TranscriptAccumulator value in _translatedTranscripts.values) {
      value.clear();
    }
    for (final SpeakerSide side in SpeakerSide.values) {
      _discardTurnAudio(side);
    }
    notifyListeners();
  }

  Future<void> replayTurn(int turnId) async {
    if (_replayingTurnId == turnId) {
      await stopReplay();
      return;
    }
    await stopReplay();
    final Uint8List? audio = _replayAudio[turnId];
    if (_disposed || audio == null || audio.isEmpty || _audioMuted) {
      return;
    }
    if (_phase == ConversationPhase.connecting ||
        _phase == ConversationPhase.reconnecting ||
        _stopOperation != null) {
      return;
    }
    final int generation = ++_replayGeneration;
    _replayingTurnId = turnId;
    _errorMessage = null;
    notifyListeners();

    late final Future<void> operation;
    operation = _runReplay(audio, generation).whenComplete(() {
      if (identical(_replayOperation, operation)) {
        _replayOperation = null;
      }
    });
    _replayOperation = operation;
    await operation;
  }

  Future<void> stopReplay() async {
    if (!_cancelReplayState()) {
      return;
    }
    await _flushPlayback();
    if (_captureSubscription == null && _stopOperation == null) {
      await _releasePlayback();
    }
  }

  bool _cancelReplayState() {
    if (_replayingTurnId == null && _replayOperation == null) {
      return false;
    }
    // Cancellation is token based. Do not wait for the old replay task here:
    // it may be inside its real-time pacing delay (or a widget-test fake
    // timer), while callers such as stopConversation must release resources
    // immediately. Once invalidated, the old task cannot enqueue another
    // chunk and its completion handler cannot clear a newer operation.
    _replayGeneration += 1;
    _replayingTurnId = null;
    _replayOperation = null;
    _resetPlaybackTimeline();
    if (!_disposed) {
      notifyListeners();
    }
    return true;
  }

  Future<void> _runReplay(Uint8List audio, int generation) async {
    final bool releaseWhenComplete = _captureSubscription == null;
    try {
      await _ensurePlaybackConfigured();
      if (!_isCurrentReplay(generation)) {
        return;
      }
      await _flushPlayback();
      if (!_isCurrentReplay(generation)) {
        return;
      }
      final int now = _monotonicMicros();
      final int durationMicros =
          audio.length *
          Duration.microsecondsPerSecond ~/
          (outputSampleRateHz * bytesPerSample);
      _scheduledPlaybackEndMicros = now + durationMicros;
      _captureBlockedUntilMicros =
          _scheduledPlaybackEndMicros +
          echoGuardMicrosForRoute(_activeOutputRoute);
      _maximumScheduledPlaybackMicros = math.max(
        _maximumScheduledPlaybackMicros,
        durationMicros,
      );
      for (
        int offset = 0;
        offset < audio.length && _isCurrentReplay(generation);
        offset += _replayChunkBytes
      ) {
        final int end = math.min(offset + _replayChunkBytes, audio.length);
        final Uint8List chunk = Uint8List.sublistView(audio, offset, end);
        _appendPlayback(() => _playback.enqueue(chunk));
        await _waitForPlayback();
        if (_playbackFailureReported || !_isCurrentReplay(generation)) {
          break;
        }
        final int chunkDurationMicros =
            chunk.length *
            Duration.microsecondsPerSecond ~/
            (outputSampleRateHz * bytesPerSample);
        await Future<void>.delayed(Duration(microseconds: chunkDurationMicros));
      }
      if (_isCurrentReplay(generation)) {
        await Future<void>.delayed(
          Duration(microseconds: echoGuardMicrosForRoute(_activeOutputRoute)),
        );
      }
    } catch (_) {
      _handlePlaybackFailure();
    } finally {
      if (_isCurrentReplay(generation)) {
        _replayingTurnId = null;
        _resetPlaybackTimeline();
        if (releaseWhenComplete) {
          await _flushPlayback();
          await _releasePlayback();
        }
        if (!_disposed) {
          notifyListeners();
        }
      }
    }
  }

  bool _isCurrentReplay(int generation) =>
      !_disposed && generation == _replayGeneration;

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
    await stopReplay();
    _conversationGeneration += 1;
    if (_diagnosticStartedMicros != null) {
      _diagnosticStoppedMicros ??= _monotonicMicros();
    }
    try {
      _sessions[_activeSpeaker]?.endAudioStream();
    } catch (_) {
      // A broken transport must not prevent local media cleanup.
    }
    _commitTurn(_activeSpeaker);
    final StreamSubscription<Uint8List>? captureSubscription =
        _captureSubscription;
    _captureSubscription = null;
    await _cancelSubscriptionBestEffort(captureSubscription);
    await _runCleanupBestEffort(_audioCapture.stop);
    await _closeSessionsBestEffort();
    await _runCleanupBestEffort(_flushPlayback);
    await _runCleanupBestEffort(_releasePlayback);
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

  void _terminateConversation(
    String message, {
    ConversationPhase phase = ConversationPhase.failed,
  }) {
    if (_disposed) {
      return;
    }
    _phase = phase;
    _errorMessage = message;
    if (_diagnosticStartedMicros != null) {
      _diagnosticStoppedMicros ??= _monotonicMicros();
    }
    notifyListeners();
    unawaited(
      _stopConversationWithOutcome(
        preserveError: true,
        finalPhase: phase,
        finalError: message,
      ),
    );
  }

  Future<void> _closeSessionsBestEffort() async {
    final List<StreamSubscription<LiveEvent>> subscriptions =
        _sessionSubscriptions.values.toList(growable: false);
    _sessionSubscriptions.clear();
    for (final StreamSubscription<LiveEvent> subscription in subscriptions) {
      await _cancelSubscriptionBestEffort(subscription);
    }

    final List<LiveTranslationSession> sessions = _sessions.values.toList(
      growable: false,
    );
    _sessions.clear();
    for (final LiveTranslationSession session in sessions) {
      await _runCleanupBestEffort(session.close);
    }
  }

  Future<void> _cancelSubscriptionBestEffort<T>(
    StreamSubscription<T>? subscription,
  ) async {
    try {
      await subscription?.cancel();
    } catch (_) {
      // Continue releasing independent resources after a callback race.
    }
  }

  Future<void> _runCleanupBestEffort(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (_) {
      // Cleanup is intentionally independent: one failed adapter or transport
      // must never leave the remaining recorder, sessions, or player alive.
    }
  }

  Future<void> _releasePlayback() async {
    try {
      await _playback.dispose();
    } catch (_) {
      _handlePlaybackFailure();
    } finally {
      _playbackConfigured = false;
      _activeOutputRoute = AudioOutputRoute.unknown;
    }
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
      audioInterruptions: _audioInterruptions,
      geminiPromptTokens: _geminiPromptTokens,
      geminiResponseTokens: _geminiResponseTokens,
      geminiTotalTokens: _geminiTotalTokens,
      geminiUsageAvailable: _geminiUsageAvailable,
      listeningReadyMilliseconds: _listeningReadyMilliseconds,
      firstMicrophoneSentMilliseconds: _firstMicrophoneSentMilliseconds,
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
    _firstMicrophoneSentMicros = null;
    _listeningReadyMilliseconds = null;
    _firstMicrophoneSentMilliseconds = null;
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
    _audioInterruptions = 0;
    _geminiPromptTokens = 0;
    _geminiResponseTokens = 0;
    _geminiTotalTokens = 0;
    _geminiUsageAvailable = false;
    _maximumScheduledPlaybackMicros = 0;
  }

  void _recordUsage(LiveUsageMetadata usage) {
    _geminiPromptTokens += usage.promptTokenCount;
    _geminiResponseTokens += usage.responseTokenCount;
    _geminiTotalTokens += usage.totalTokenCount;
    _geminiUsageAvailable = true;
  }

  int _elapsedDiagnosticMilliseconds() {
    return _elapsedDiagnosticMillisecondsAt(_monotonicMicros());
  }

  int _elapsedDiagnosticMillisecondsAt(int nowMicros) {
    final int? startedMicros = _diagnosticStartedMicros;
    if (startedMicros == null) {
      return 0;
    }
    return math.max(0, nowMicros - startedMicros) ~/
        Duration.microsecondsPerMillisecond;
  }

  int _elapsedFromFirstSendMilliseconds() {
    final int now = _monotonicMicros();
    final int baseline =
        _firstMicrophoneSentMicros ?? _diagnosticStartedMicros ?? now;
    return math.max(0, now - baseline) ~/ Duration.microsecondsPerMillisecond;
  }

  @override
  void dispose() {
    _disposed = true;
    _conversationGeneration += 1;
    unawaited(_disposeResources());
    super.dispose();
  }

  Future<void> _disposeResources() async {
    final Future<void>? stopOperation = _stopOperation;
    if (stopOperation != null) {
      await _runCleanupBestEffort(() => stopOperation);
    }
    await _runCleanupBestEffort(stopReplay);
    try {
      await _playbackEventSubscription?.cancel();
    } catch (_) {
      // Continue releasing the remaining resources.
    } finally {
      _playbackEventSubscription = null;
    }
    try {
      await _permissionSubscription?.cancel();
    } catch (_) {
      // Continue releasing the remaining resources.
    } finally {
      _permissionSubscription = null;
    }
    try {
      await _captureSubscription?.cancel();
    } catch (_) {
      // Continue releasing the remaining resources.
    } finally {
      _captureSubscription = null;
    }
    await _runCleanupBestEffort(_audioCapture.dispose);
    await _closeSessionsBestEffort();
    await _runCleanupBestEffort(_flushPlayback);
    await _runCleanupBestEffort(_releasePlayback);
  }
}
