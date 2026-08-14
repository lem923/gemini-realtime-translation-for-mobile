import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../audio/audio_capture_gateway.dart';
import '../audio/audio_constants.dart';
import '../audio/headset_capture_gateway.dart';
import '../audio/pcm_playback_gateway.dart';
import '../audio/speech_activity_detector.dart';
import '../live_translate/live_event.dart';
import '../live_translate/live_translation_session.dart';
import '../permissions/microphone_permission_gateway.dart';
import '../preferences/language_pair_store.dart';
import '../security/api_key_store.dart';
import '../shared/translation_language.dart';
import 'conversation_diagnostics.dart';
import 'conversation_models.dart';

enum _PersistedKeyState { unknown, absent, present }

class ConversationController extends ChangeNotifier {
  ConversationController({
    ApiKeyStore? keyStore,
    AudioCaptureGateway? audioCapture,
    PcmPlaybackGateway? playback,
    HeadsetCaptureGateway? headsetCapture,
    LanguagePairStore? languagePairStore,
    MicrophonePermissionGateway? permissionGateway,
    LiveSessionFactory? sessionFactory,
    int Function()? monotonicMicros,
    this.cleanupTimeout = const Duration(seconds: 2),
    this.tailGraceDuration = const Duration(milliseconds: 2000),
  }) : _keyStore = keyStore ?? SecureApiKeyStore(),
       _audioCapture = audioCapture ?? RecordAudioCaptureGateway(),
       _playback = playback ?? PlatformPcmPlaybackGateway(),
       _headsetCapture = headsetCapture ?? NativeHeadsetCaptureGateway(),
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
  final HeadsetCaptureGateway _headsetCapture;
  final LanguagePairStore _languagePairStore;
  final MicrophonePermissionGateway _permissionGateway;
  final LiveSessionFactory _sessionFactory;
  final int Function() _monotonicMicros;
  @visibleForTesting
  final Duration cleanupTimeout;
  final Duration tailGraceDuration;
  bool _tailGraceActive = false;
  final Map<SpeakerSide, LiveTranslationSession> _sessions =
      <SpeakerSide, LiveTranslationSession>{};
  SpeechActivityDetector _speechDetector = SpeechActivityDetector();
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
  StreamSubscription<Uint8List>? _headsetSubscription;
  SpeechActivityDetector _headsetDetector = SpeechActivityDetector();
  HeadsetCaptureState _headsetState = HeadsetCaptureState.unavailable;
  StreamSubscription<PcmPlaybackEvent>? _playbackEventSubscription;
  StreamSubscription<MicrophonePermissionStatus>? _permissionSubscription;
  Future<void> _playbackChain = Future<void>.value();
  Future<void>? _stopOperation;
  Future<void>? _replayOperation;
  Future<void>? _keyInvalidationOperation;
  Future<void>? _playbackDisposalOperation;
  bool _pendingStopPreserveError = false;
  ConversationPhase? _pendingStopFinalPhase;
  String? _pendingStopFinalError;
  String _apiKey = '';
  bool _rememberKey = false;
  _PersistedKeyState _persistedKeyState = _PersistedKeyState.unknown;
  String? _desiredPersistedKey;
  int _keyPersistenceIntentGeneration = 0;
  bool _initialized = false;
  bool _audioMuted = false;
  bool _disposed = false;
  bool _playbackFailureReported = false;
  int _playbackAutoRecoveries = 0;
  bool _playbackConfigured = false;
  bool _microphonePermissionGrantedOnce = false;
  AudioOutputRoute _activeOutputRoute = AudioOutputRoute.unknown;
  int _captureBlockedUntilMicros = 0;
  int _scheduledPlaybackEndMicros = 0;
  int _conversationGeneration = 0;
  int _replayGeneration = 0;
  int _playbackGeneration = 0;
  int _playbackFlushesInFlight = 0;
  int _captureRecoveryAttempts = 0;
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
  int _microphoneChunksHeld = 0;
  int _utterancesDetected = 0;
  ConversationMode _diagnosticMode = ConversationMode.sentenceBySentence;
  int _bargeIns = 0;
  int _sentenceTurnsCompleted = 0;
  int _autoDirectionSwitches = 0;
  int _suppressedSpeechStreak = 0;
  int _lastBargeInMicros = -bargeInCooldownMicros;
  int _outputAudioChunks = 0;
  int _outputAudioBytes = 0;
  int _diagnosticCompletedTurns = 0;
  int _directionSwitches = 0;
  int _reconnectEvents = 0;
  int _sessionFailures = 0;
  int _playbackFailures = 0;
  String? _lastPlaybackFailureReason;
  int? _lastPlaybackFailurePlatformCode;
  int _audioInterruptions = 0;
  int _geminiPromptTokens = 0;
  int _geminiResponseTokens = 0;
  int _geminiTotalTokens = 0;
  bool _geminiUsageAvailable = false;
  int _maximumScheduledPlaybackMicros = 0;
  String? _errorMessage;
  ConversationPhase _phase = ConversationPhase.needsKey;
  SpeakerSide _activeSpeaker = SpeakerSide.a;
  ConversationMode _mode = ConversationMode.sentenceBySentence;
  LectureInputChannel _lectureChannel = LectureInputChannel.phoneMic;
  TranslationLanguage _languageA = languageByCode('zh-Hans');
  TranslationLanguage _languageB = languageByCode('en');
  final List<ConversationTurn> _turns = <ConversationTurn>[];
  final Map<SpeakerSide, BytesBuilder> _turnAudio = <SpeakerSide, BytesBuilder>{
    SpeakerSide.a: BytesBuilder(copy: true),
    SpeakerSide.b: BytesBuilder(copy: true),
  };
  bool _pttActive = false;
  final Map<SpeakerSide, List<Uint8List>> _sentencePlaybackChunks =
      <SpeakerSide, List<Uint8List>>{
        SpeakerSide.a: <Uint8List>[],
        SpeakerSide.b: <Uint8List>[],
      };
  final Map<SpeakerSide, bool> _sentencePlaybackFinalized = <SpeakerSide, bool>{
    SpeakerSide.a: false,
    SpeakerSide.b: false,
  };
  final Map<SpeakerSide, bool> _sentencePlaybackDraining = <SpeakerSide, bool>{
    SpeakerSide.a: false,
    SpeakerSide.b: false,
  };
  int _sentencePlaybackBytes = 0;
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
  static const int maxSentencePlaybackBytes =
      outputSampleRateHz * bytesPerSample * 90;
  static const int maxCaptureRecoveryAttempts = 3;
  static const Duration captureRecoveryDelay = Duration(milliseconds: 300);
  static const int bargeInSpeechChunks = 3;
  static const int bargeInCooldownMicros = 1500000;
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
  ConversationMode get mode => _mode;
  LectureInputChannel get lectureChannel => _lectureChannel;
  TranslationLanguage get lectureSourceLanguage => _languageA;
  TranslationLanguage get lectureTargetLanguage => _languageB;
  HeadsetCaptureState get headsetState => _headsetState;
  bool get isHeadsetMode => _mode == ConversationMode.lecture;
  bool get pttActive => _pttActive;
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
      _persistedKeyState = stored == null || stored.trim().isEmpty
          ? _PersistedKeyState.absent
          : _PersistedKeyState.present;
      _setKeyPersistenceIntent(
        _persistedKeyState == _PersistedKeyState.present
            ? stored?.trim()
            : null,
      );
    } catch (_) {
      _persistedKeyState = _PersistedKeyState.unknown;
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
    await _keyInvalidationOperation;
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
    } catch (_) {
      _phase = hasApiKey ? ConversationPhase.idle : ConversationPhase.needsKey;
      _errorMessage = probeFailure ?? '验证失败，请检查 Key、模型权限与网络';
      notifyListeners();
      return false;
    } finally {
      await _cancelSubscriptionBestEffort(subscription);
      await _runCleanupBestEffort(probe.close);
    }

    var effectiveRemember = remember;
    String? storageWarning;
    if (remember) {
      _setKeyPersistenceIntent(key);
      try {
        await _keyStore.write(key);
        _persistedKeyState = _PersistedKeyState.present;
      } catch (_) {
        _setKeyPersistenceIntent(null);
        // A validated key remains useful in the current process. Try to remove
        // a possibly partial/stale write before describing it as memory-only.
        try {
          await _keyStore.delete();
          _persistedKeyState = _PersistedKeyState.absent;
          storageWarning = 'Key 已验证，但无法安全保存；本次仅保存在内存中';
        } catch (_) {
          _persistedKeyState = _PersistedKeyState.unknown;
          storageWarning = 'Key 已验证并可用于本次会话，但设备安全存储状态未知；请重试移除或清除应用数据';
        }
        effectiveRemember = false;
      }
    } else if (_persistedKeyState != _PersistedKeyState.absent) {
      _setKeyPersistenceIntent(null);
      try {
        await _keyStore.delete();
        _persistedKeyState = _PersistedKeyState.absent;
      } catch (_) {
        _persistedKeyState = _PersistedKeyState.unknown;
        storageWarning = 'Key 已验证并可用于本次会话，但无法确认设备副本已清除；请重试移除或清除应用数据';
      }
    } else {
      _setKeyPersistenceIntent(null);
    }

    _apiKey = key;
    _rememberKey = effectiveRemember;
    _phase = ConversationPhase.idle;
    _errorMessage = storageWarning;
    notifyListeners();
    return true;
  }

  Future<void> removeApiKey() async {
    await _keyInvalidationOperation;
    await stopConversation();
    _apiKey = '';
    _rememberKey = false;
    _setKeyPersistenceIntent(null);
    _phase = ConversationPhase.needsKey;
    try {
      await _keyStore.delete();
      _persistedKeyState = _PersistedKeyState.absent;
      _errorMessage = null;
    } catch (_) {
      _persistedKeyState = _PersistedKeyState.unknown;
      _errorMessage = '已从当前会话移除 Key，但无法清除设备安全存储；请清除应用数据';
    }
    notifyListeners();
  }

  Future<void> startConversation() async {
    if (!hasApiKey || isBusy || isListening) {
      return;
    }
    _phase = ConversationPhase.connecting;
    _errorMessage = null;
    _resetDiagnostics(_monotonicMicros());
    _diagnosticMode = _mode;
    // A playback failure or audio interruption in an earlier conversation
    // must not silence the new one: mute is a per-conversation state.
    _audioMuted = false;
    _playbackFailureReported = false;
    final int generation = ++_conversationGeneration;
    _captureRecoveryAttempts = 0;
    _speechDetector = SpeechActivityDetector();
    _headsetDetector = SpeechActivityDetector();
    _clearAllSentencePlayback();
    _suppressedSpeechStreak = 0;
    _lastBargeInMicros = -bargeInCooldownMicros;
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
      await _ensureSelectedSession(generation);
      if (!_isCurrentConversation(generation)) {
        return;
      }
      final Stream<Uint8List> stream = await _audioCapture.start();
      if (!_isCurrentConversation(generation)) {
        await _audioCapture.stop();
        return;
      }
      // The user may switch the selected speaker while native capture is
      // starting. Re-check the latest direction before accepting any frame.
      if (_mode != ConversationMode.sentenceBySentence) {
        await _ensureSelectedSession(generation);
        if (!_isCurrentConversation(generation)) {
          await _audioCapture.stop();
          return;
        }
      }
      var captureTerminated = false;
      void handleCaptureTermination(String message) {
        if (captureTerminated) {
          return;
        }
        captureTerminated = true;
        if (_isCurrentConversation(generation) && _stopOperation == null) {
          unawaited(_recoverOrTerminateCapture(generation, message));
        }
      }

      // The active subscription is cancelled through _captureSubscription when
      // the capture is replaced, stopped, or recovered.
      // ignore: cancel_subscriptions
      final StreamSubscription<Uint8List> captureSubscription =
          _subscribeToCapture(
            stream: stream,
            generation: generation,
            onTermination: handleCaptureTermination,
          );
      _captureSubscription = captureSubscription;
      if (isHeadsetMode && _lectureChannel == LectureInputChannel.headsetMic) {
        final HeadsetCaptureState headsetState = await _headsetCapture.state();
        _headsetState = headsetState;
        if (!_isCurrentConversation(generation)) {
          return;
        }
        if (headsetState != HeadsetCaptureState.available) {
          await _audioCapture.stop();
          _terminateConversation('讲座模式选择了耳机麦克风，但未检测到带麦克风的耳机');
          return;
        }
        final Stream<Uint8List> headsetStream = await _headsetCapture.start();
        if (!_isCurrentConversation(generation)) {
          await _headsetCapture.stop();
          return;
        }
        var headsetTerminated = false;
        void handleHeadsetTermination() {
          if (headsetTerminated) {
            return;
          }
          headsetTerminated = true;
          if (_isCurrentConversation(generation) && _stopOperation == null) {
            _terminateConversation('耳机麦克风连接中断，请重新连接耳机');
          }
        }

        late final StreamSubscription<Uint8List> headsetSubscription;
        headsetSubscription = headsetStream.listen(
          (Uint8List chunk) {
            if (_isCurrentConversation(generation) &&
                identical(_headsetSubscription, headsetSubscription)) {
              _routeHeadsetChunk(chunk);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (identical(_headsetSubscription, headsetSubscription)) {
              handleHeadsetTermination();
            }
          },
          onDone: () {
            if (identical(_headsetSubscription, headsetSubscription)) {
              handleHeadsetTermination();
            }
          },
          cancelOnError: false,
        );
        _headsetSubscription = headsetSubscription;
      }
      _phase = ConversationPhase.listening;
      _listeningReadyMilliseconds ??= _elapsedDiagnosticMilliseconds();
      notifyListeners();
      if (!isHeadsetMode) {
        final SpeakerSide standby = _otherSide(_activeSpeaker);
        unawaited(_ensureSession(standby).catchError((Object _) {}));
      }
    } catch (error) {
      if (!_isCurrentConversation(generation)) {
        final Future<void>? stopping = _stopOperation;
        if (stopping != null) {
          await stopping;
        }
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
    if (_stopOperation != null) {
      _phase = ConversationPhase.permissionDenied;
      _errorMessage = message;
      notifyListeners();
      unawaited(
        _stopConversationWithOutcome(
          preserveError: true,
          drainPlayback: false,
          finalPhase: ConversationPhase.permissionDenied,
          finalError: message,
        ),
      );
      return;
    }
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
      final LiveTranslationSession createdSession = _sessionFactory(
        apiKey: _apiKey,
        targetLanguageCode: target.code,
      );
      final int generation = _conversationGeneration;
      session = createdSession;
      _sessions[side] = session;
      _sessionSubscriptions[side] = session.events.listen((LiveEvent event) {
        if (!identical(_sessions[side], createdSession)) {
          return;
        }
        if (_isCurrentConversation(generation)) {
          _handleLiveEvent(side, event);
          return;
        }
        // During a graceful stop, the model's final audio still plays out:
        // accept only the audio tail and the turn completion.
        if (_tailGraceActive &&
            (event is LiveAudioChunk || event is LiveTurnComplete)) {
          _handleLiveEvent(side, event);
        }
      });
    }
    if (!session.isReady) {
      await session.connect();
    }
  }

  Future<void> _ensureSelectedSession(int generation) async {
    while (_isCurrentConversation(generation)) {
      final SpeakerSide selectedSide = _activeSpeaker;
      await _ensureSession(selectedSide);
      if (selectedSide == _activeSpeaker) {
        return;
      }
    }
  }

  void _routeMicrophoneChunk(Uint8List chunk) {
    if (!isListening) {
      return;
    }
    final LiveTranslationSession? session = _sessions[_activeSpeaker];
    if (session?.isReady != true) {
      return;
    }
    final SpeechGateDecision decision = _speechDetector.add(chunk);
    final int now = _monotonicMicros();
    if (isHeadsetMode) {
      // Lecture mode: no echo guard (translations play on the headset) and
      // utterances finalize with a stream end.
      switch (decision) {
        case SpeechGateDecision.hold:
          _microphoneChunksHeld += 1;
        case SpeechGateDecision.finalize:
          _microphoneChunksHeld += 1;
          _utterancesDetected += 1;
          try {
            session!.endAudioStream();
          } catch (_) {
            // A broken transport must not prevent the next utterance.
          }
        case SpeechGateDecision.forward:
          _sendMicrophoneChunk(session!, chunk);
      }
      return;
    }
    if (_mode == ConversationMode.sentenceBySentence) {
      // Push-to-talk: forwarded speech streams to the live translation
      // session while the button is held; the translated audio is buffered
      // and played only after the button is released.
      if (_pttActive && decision == SpeechGateDecision.forward) {
        _sendMicrophoneChunk(session!, chunk);
      } else if (decision == SpeechGateDecision.hold ||
          decision == SpeechGateDecision.finalize) {
        _microphoneChunksHeld += 1;
      }
      return;
    }
    final bool echoGuarded =
        _mode == ConversationMode.sentenceBySentence &&
        (_playbackFlushesInFlight > 0 || now < _captureBlockedUntilMicros);
    if (echoGuarded) {
      if (decision == SpeechGateDecision.forward &&
          _playbackFlushesInFlight == 0) {
        _suppressedSpeechStreak += 1;
        if (_suppressedSpeechStreak >= bargeInSpeechChunks &&
            now - _lastBargeInMicros >= bargeInCooldownMicros) {
          _suppressedSpeechStreak = 0;
          _lastBargeInMicros = now;
          _bargeIns += 1;
          // The user is talking over the translation: cut the translated
          // playback and reopen the microphone for the new utterance. The
          // current chunk is forwarded so no speech is lost.
          _sendMicrophoneChunk(session!, chunk);
          unawaited(_flushPlayback());
          return;
        }
      } else {
        _suppressedSpeechStreak = 0;
      }
      _microphoneChunksSuppressed += 1;
      return;
    }
    _suppressedSpeechStreak = 0;
    switch (decision) {
      case SpeechGateDecision.hold:
        _microphoneChunksHeld += 1;
      case SpeechGateDecision.finalize:
        _microphoneChunksHeld += 1;
        _utterancesDetected += 1;
        // Every utterance end flushes the server's cached audio with an
        // explicit turn boundary; without it the server holds the final
        // translation and the last words never play.
        try {
          session!.endAudioStream();
        } catch (_) {
          // A broken transport must not prevent the next utterance; the
          // session state machine reports and reconnects on its own.
        }
        if (_mode == ConversationMode.sentenceBySentence) {
          _startSentencePlayback(_activeSpeaker);
        }
      case SpeechGateDecision.forward:
        _sendMicrophoneChunk(session!, chunk);
    }
  }

  /// Routes the headset microphone, which belongs to speaker A. The headset
  /// stream is unguarded: the headset earpiece is acoustically isolated from
  /// its own microphone.
  void _routeHeadsetChunk(Uint8List chunk) {
    if (!isListening) {
      return;
    }
    final LiveTranslationSession? session = _sessions[_activeSpeaker];
    if (session?.isReady != true) {
      return;
    }
    final SpeechGateDecision decision = _headsetDetector.add(chunk);
    switch (decision) {
      case SpeechGateDecision.hold:
        _microphoneChunksHeld += 1;
      case SpeechGateDecision.finalize:
        _microphoneChunksHeld += 1;
        _utterancesDetected += 1;
        try {
          session!.endAudioStream();
        } catch (_) {
          // A broken transport must not prevent the next utterance.
        }
      case SpeechGateDecision.forward:
        _sendMicrophoneChunk(session!, chunk);
    }
  }

  /// Push-to-talk: while the button is held, speech streams to the live
  /// translation session; release finalizes the utterance and plays the
  /// buffered translated audio.
  void startUtterance() {
    if (_disposed || _pttActive) {
      return;
    }
    if (!hasApiKey ||
        _phase == ConversationPhase.needsKey ||
        _phase == ConversationPhase.permissionDenied) {
      return;
    }
    if (!isListening) {
      unawaited(startConversation());
    }
    if (_replayingTurnId != null || _replayOperation != null) {
      unawaited(stopReplay());
    }
    _pttActive = true;
    // A fresh utterance starts with an empty playback buffer.
    _clearSentencePlayback(_activeSpeaker);
    _errorMessage = null;
    // Cut any translation still playing so the new utterance wins.
    unawaited(_flushPlayback());
    notifyListeners();
  }

  void endUtterance() {
    if (!_pttActive) {
      return;
    }
    _pttActive = false;
    notifyListeners();
    unawaited(_finalizeSentenceUtterance());
  }

  Future<void> _finalizeSentenceUtterance() async {
    final LiveTranslationSession? session = _sessions[_activeSpeaker];
    if (session?.isReady == true) {
      try {
        session!.endAudioStream();
      } catch (_) {
        // A broken transport must not prevent the buffered playback.
      }
    }
    // Play the whole buffered translation only after the button is released.
    _startSentencePlayback(_activeSpeaker);
  }

  void _sendMicrophoneChunk(LiveTranslationSession session, Uint8List chunk) {
    final int now = _monotonicMicros();
    try {
      session.sendAudio(chunk);
      _firstMicrophoneSentMicros ??= now;
      _firstMicrophoneSentMilliseconds ??= _elapsedDiagnosticMillisecondsAt(
        now,
      );
      _microphoneChunksSent += 1;
    } catch (_) {
      _terminateConversation('连接已中断，请检查网络后重试');
    }
  }

  StreamSubscription<Uint8List> _subscribeToCapture({
    required Stream<Uint8List> stream,
    required int generation,
    required void Function(String message) onTermination,
  }) {
    late final StreamSubscription<Uint8List> subscription;
    subscription = stream.listen(
      (Uint8List chunk) {
        if (_isCurrentConversation(generation) &&
            identical(_captureSubscription, subscription)) {
          _routeMicrophoneChunk(chunk);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_captureSubscription, subscription)) {
          onTermination('麦克风采集失败，请重试');
        }
      },
      onDone: () {
        if (identical(_captureSubscription, subscription)) {
          onTermination('麦克风采集已停止，请重试');
        }
      },
      cancelOnError: false,
    );
    return subscription;
  }

  Future<void> _recoverOrTerminateCapture(
    int generation,
    String message,
  ) async {
    if (!_isCurrentConversation(generation) || _stopOperation != null) {
      return;
    }
    if (_captureRecoveryAttempts >= maxCaptureRecoveryAttempts) {
      _terminateConversation(message);
      return;
    }
    _captureRecoveryAttempts += 1;
    final SpeakerSide side = _activeSpeaker;
    try {
      _sessions[side]?.endAudioStream();
    } catch (_) {
      // A broken transport must not prevent capture recovery.
    }
    try {
      await _audioCapture.stop();
    } catch (_) {
      // The authoritative start below replaces a recorder that failed to stop.
    }
    await Future<void>.delayed(captureRecoveryDelay);
    if (!_isCurrentConversation(generation) || _stopOperation != null) {
      return;
    }
    try {
      final Stream<Uint8List> stream = await _audioCapture.start();
      if (!_isCurrentConversation(generation) || _stopOperation != null) {
        await _audioCapture.stop();
        return;
      }
      var recoveredTerminated = false;
      void onTermination(String nextMessage) {
        if (recoveredTerminated) {
          return;
        }
        recoveredTerminated = true;
        if (_isCurrentConversation(generation) && _stopOperation == null) {
          unawaited(_recoverOrTerminateCapture(generation, nextMessage));
        }
      }

      // The replacement subscription is owned by _captureSubscription until
      // the capture is replaced, stopped, or recovered again.
      // ignore: cancel_subscriptions
      final StreamSubscription<Uint8List> subscription = _subscribeToCapture(
        stream: stream,
        generation: generation,
        onTermination: onTermination,
      );
      final StreamSubscription<Uint8List>? previous = _captureSubscription;
      _captureSubscription = subscription;
      await _cancelSubscriptionBestEffort(previous);
    } catch (_) {
      if (_isCurrentConversation(generation) && _stopOperation == null) {
        _terminateConversation(message);
      }
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
            if (_mode == ConversationMode.sentenceBySentence) {
              _bufferSentenceAudio(side, bytes);
            } else if (isHeadsetMode) {
              _queueTrackPlayback(side, bytes);
            } else {
              _queuePlayback(bytes);
            }
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
          _clearSentencePlayback(side);
          // Interruption is an explicit turn boundary. Keep already visible
          // text, but never merge it into the next utterance or replay stale
          // audio from the interrupted response.
          _commitTurn(side);
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
          if (authenticationFailure) {
            _invalidateApiKeyAfterAuthenticationFailure(userMessage);
          } else if (!retryable) {
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
      case LiveResumptionHandle() || LiveGoAway() || LiveCompressionUpdate():
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
    if (_mode == ConversationMode.sentenceBySentence) {
      _captureBlockedUntilMicros =
          _scheduledPlaybackEndMicros +
          echoGuardMicrosForRoute(_activeOutputRoute);
    }
    _appendPlayback(() => _playback.enqueue(bytes));
  }

  /// Sentence-by-sentence playback: translated audio is buffered while the
  /// speaker is still talking and starts playing only once the utterance is
  /// finalized, so the user never hears the translation while speaking.
  void _bufferSentenceAudio(SpeakerSide side, Uint8List bytes) {
    if (_sentencePlaybackFinalized[side] == true) {
      _queuePlayback(bytes);
      return;
    }
    final List<Uint8List> chunks = _sentencePlaybackChunks[side]!;
    chunks.add(bytes);
    _sentencePlaybackBytes += bytes.length;
    while (_sentencePlaybackBytes > maxSentencePlaybackBytes &&
        chunks.isNotEmpty) {
      final Uint8List removed = chunks.removeAt(0);
      _sentencePlaybackBytes -= removed.length;
    }
  }

  void _startSentencePlayback(SpeakerSide side) {
    _sentencePlaybackFinalized[side] = true;
    if (_sentencePlaybackDraining[side] == true) {
      return;
    }
    unawaited(_drainSentencePlayback(side));
  }

  Future<void> _drainSentencePlayback(SpeakerSide side) async {
    _sentencePlaybackDraining[side] = true;
    try {
      while (!_disposed && !_playbackFailureReported) {
        final List<Uint8List> chunks = _sentencePlaybackChunks[side]!;
        if (chunks.isEmpty) {
          break;
        }
        final Uint8List chunk = chunks.removeAt(0);
        _sentencePlaybackBytes -= chunk.length;
        _queuePlayback(chunk);
        // The native lane applies backpressure: enqueue blocks until audio
        // is consumed, so no pacing delay is needed here and playback never
        // starves.
        await _waitForPlayback();
      }
    } finally {
      _sentencePlaybackDraining[side] = false;
    }
  }

  void _clearSentencePlayback(SpeakerSide side) {
    _sentencePlaybackBytes -= _sentencePlaybackChunks[side]!.fold(
      0,
      (int total, Uint8List chunk) => total + chunk.length,
    );
    _sentencePlaybackChunks[side]!.clear();
    _sentencePlaybackFinalized[side] = false;
  }

  void _clearAllSentencePlayback() {
    for (final SpeakerSide side in SpeakerSide.values) {
      _clearSentencePlayback(side);
    }
  }

  /// Lecture-mode playback: every translation plays on the headset.
  void _queueTrackPlayback(SpeakerSide side, Uint8List bytes) {
    _appendPlayback(() => _playback.enqueueTrack(PlaybackTrack.headset, bytes));
  }

  void _appendPlayback(Future<void> Function() operation) {
    final int generation = _playbackGeneration;
    _playbackChain = _playbackChain
        .then((_) {
          if (generation != _playbackGeneration) {
            return Future<void>.value();
          }
          return operation();
        })
        .catchError((Object error, StackTrace stackTrace) {
          if (generation == _playbackGeneration) {
            _handlePlaybackFailure(reason: error.toString());
          }
        });
  }

  Future<void> _waitForPlayback() => _playbackChain;

  Future<void> _ensurePlaybackConfigured() async {
    while (_playbackDisposalOperation != null) {
      final Future<void> disposing = _playbackDisposalOperation!;
      await disposing;
    }
    await _waitForPlayback();
    if (_playbackConfigured) {
      return;
    }
    final int generation = _playbackGeneration;
    await _playback.configure(
      clientGeneration: generation,
      forceSpeakerToPhone: isHeadsetMode,
    );
    if (generation != _playbackGeneration) {
      return;
    }
    _playbackConfigured = true;
    _resetPlaybackTimeline();
  }

  Future<void> _flushPlayback() {
    final int generation = _playbackGeneration;
    _playbackFlushesInFlight += 1;
    _resetPlaybackTimeline();
    _appendPlayback(_playback.flush);
    return _playbackChain.whenComplete(() {
      if (generation == _playbackGeneration) {
        _playbackFlushesInFlight = math.max(0, _playbackFlushesInFlight - 1);
      }
    });
  }

  void _invalidatePlaybackOperations() {
    _playbackGeneration += 1;
    _playbackFlushesInFlight = 0;
    _playbackChain = Future<void>.value();
    _resetPlaybackTimeline();
  }

  void _resetPlaybackTimeline() {
    final int now = _monotonicMicros();
    _scheduledPlaybackEndMicros = now;
    _captureBlockedUntilMicros = now;
  }

  void _handlePlaybackFailure({
    String? reason,
    int? platformCode,
  }) {
    if (_disposed || _playbackFailureReported) {
      return;
    }
    _playbackFailureReported = true;
    _playbackFailures += 1;
    _lastPlaybackFailureReason = reason;
    _lastPlaybackFailurePlatformCode = platformCode;
    _audioMuted = true;
    _invalidatePlaybackOperations();
    _playbackConfigured = false;
    _activeOutputRoute = AudioOutputRoute.unknown;
    unawaited(_releasePlayback());
    _errorMessage = '译音播放失败，文字翻译仍可继续';
    notifyListeners();
    // One automatic recovery attempt: transient native failures (route or
    // HAL state) are replayed with a fresh configuration shortly after.
    if (_playbackAutoRecoveries < 1) {
      _playbackAutoRecoveries += 1;
      unawaited(_recoverPlaybackOnce());
    }
  }

  Future<void> _recoverPlaybackOnce() async {
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (_disposed ||
        !_playbackFailureReported ||
        _stopOperation != null ||
        _captureSubscription == null) {
      return;
    }
    _playbackFailureReported = false;
    try {
      await _ensurePlaybackConfigured();
      if (_disposed || _playbackFailureReported) {
        return;
      }
      _audioMuted = false;
      _errorMessage = null;
      notifyListeners();
    } catch (_) {
      // The failure is persistent; stay in text-only mode with the message.
      _playbackFailureReported = true;
    }
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
    if (event is PcmPlaybackFailed) {
      if (event.clientGeneration != _playbackGeneration) {
        return;
      }
      _handlePlaybackFailure(
        reason: event.reason,
        platformCode: event.platformCode,
      );
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
    if (_audioMuted && !_playbackConfigured) {
      // The interrupted run is already retired; a duplicate system event must
      // not repeat the diagnostics or the user message.
      return;
    }
    _audioInterruptions += 1;
    // An audio-focus interruption retires only the interrupted playback run.
    // The Gemini sessions and microphone stay alive: translated text keeps
    // flowing and the user can restore voice with the unmute control. Only
    // explicit stop, direction change, or permission revocation may end the
    // stream.
    _audioMuted = true;
    _playbackFailureReported = false;
    _invalidatePlaybackOperations();
    _playbackConfigured = false;
    _activeOutputRoute = AudioOutputRoute.unknown;
    unawaited(_releasePlayback());
    _errorMessage = '译音被系统中断，文字翻译继续；点顶部音量按钮可恢复语音';
    notifyListeners();
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
    if (_mode == ConversationMode.sentenceBySentence) {
      _sentenceTurnsCompleted += 1;
    }
    source.clear();
    translated.clear();
    notifyListeners();
  }

  void setLectureChannel(LectureInputChannel channel) {
    if (_lectureChannel == channel || _disposed) {
      return;
    }
    _lectureChannel = channel;
    _errorMessage = null;
    notifyListeners();
  }

  void setMode(ConversationMode mode) {
    if (_mode == mode || _disposed) {
      return;
    }
    if (isListening || _stopOperation != null || isBusy) {
      // Switching modes restarts the conversation with the new configuration.
      unawaited(stopConversation());
    }
    _mode = mode;
    _errorMessage = null;
    if (mode != ConversationMode.sentenceBySentence) {
      _clearAllSentencePlayback();
    }
    if (mode == ConversationMode.lecture) {
      unawaited(_refreshHeadsetState());
    }
    notifyListeners();
  }

  Future<void> _refreshHeadsetState() async {
    try {
      final HeadsetCaptureState state = await _headsetCapture.state();
      if (_disposed || _mode != ConversationMode.lecture) {
        return;
      }
      _headsetState = state;
      notifyListeners();
    } catch (_) {
      _headsetState = HeadsetCaptureState.unavailable;
    }
  }

  Future<void> selectSpeaker(SpeakerSide side) async {
    if (isHeadsetMode) {
      // Direction is detected automatically in headset-split mode.
      return;
    }
    if (_replayingTurnId != null || _replayOperation != null) {
      await stopReplay();
    }
    if (side == _activeSpeaker) {
      return;
    }
    if (_diagnosticStartedMicros != null && _diagnosticStoppedMicros == null) {
      _directionSwitches += 1;
    }
    final SpeakerSide previousSide = _activeSpeaker;
    _clearSentencePlayback(previousSide);
    try {
      _sessions[previousSide]?.endAudioStream();
    } catch (_) {
      // Direction switching remains usable even if the old transport has
      // already closed between its ready signal and the turn boundary.
    }
    _commitTurn(previousSide);
    final Future<void>? retiringPrevious = _captureSubscription == null
        ? null
        : _retireSession(previousSide);
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
          if (retiringPrevious != null) {
            unawaited(
              retiringPrevious
                  .then((_) {
                    if (_isCurrentConversation(generation) &&
                        _activeSpeaker != previousSide) {
                      return _ensureSession(previousSide);
                    }
                  })
                  .catchError((Object _) {}),
            );
          }
        }
      } catch (_) {
        if (_isCurrentConversation(generation) && side == _activeSpeaker) {
          _terminateConversation('切换方向失败，请检查连接后重试');
        }
      }
    }
    notifyListeners();
  }

  Future<void> _retireSession(SpeakerSide side) async {
    final StreamSubscription<LiveEvent>? subscription = _sessionSubscriptions
        .remove(side);
    final LiveTranslationSession? session = _sessions.remove(side);
    await Future.wait(<Future<void>>[
      _cancelSubscriptionBestEffort(subscription),
      if (session != null) _runCleanupBestEffort(session.close),
    ]);
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
    if (!_audioMuted) {
      _audioMuted = true;
      if (_replayingTurnId != null || _replayOperation != null) {
        unawaited(stopReplay());
      } else {
        unawaited(_flushPlayback());
      }
    } else {
      _playbackFailureReported = false;
      unawaited(_restoreAudioOutput());
    }
    notifyListeners();
  }

  Future<void> _restoreAudioOutput() async {
    try {
      await _ensurePlaybackConfigured();
      if (_disposed || _playbackFailureReported) {
        return;
      }
      _audioMuted = false;
      _errorMessage = null;
      notifyListeners();
    } catch (error) {
      _playbackFailureReported = false;
      _handlePlaybackFailure(reason: error.toString());
    }
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
      }
      if (_isCurrentReplay(generation)) {
        await Future<void>.delayed(
          Duration(microseconds: echoGuardMicrosForRoute(_activeOutputRoute)),
        );
      }
    } catch (error) {
      _handlePlaybackFailure(reason: error.toString());
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

  Future<void> stopConversation({
    bool preserveError = false,
    bool drainPlayback = false,
  }) {
    return _stopConversationWithOutcome(
      preserveError: preserveError,
      drainPlayback: drainPlayback,
    );
  }

  Future<void> _stopConversationWithOutcome({
    required bool preserveError,
    required bool drainPlayback,
    ConversationPhase? finalPhase,
    String? finalError,
  }) {
    _mergePendingStopOutcome(
      preserveError: preserveError,
      finalPhase: finalPhase,
      finalError: finalError,
    );
    final Future<void>? inFlight = _stopOperation;
    if (inFlight != null) {
      return inFlight;
    }
    final Completer<void> operationCompleter = Completer<void>();
    final Future<void> operation = operationCompleter.future;
    _stopOperation = operation;
    unawaited(
      _runStopOperation(
        operationCompleter: operationCompleter,
        operation: operation,
        preserveError: preserveError,
        drainPlayback: drainPlayback,
      ),
    );
    return operation;
  }

  Future<void> _runStopOperation({
    required Completer<void> operationCompleter,
    required Future<void> operation,
    required bool preserveError,
    required bool drainPlayback,
  }) async {
    Object? failure;
    StackTrace? failureStackTrace;
    try {
      await _stopConversationInternal(
        preserveError: preserveError,
        drainPlayback: drainPlayback,
      );
    } catch (error, stackTrace) {
      failure = error;
      failureStackTrace = stackTrace;
    }
    if (identical(_stopOperation, operation)) {
      _stopOperation = null;
      _pendingStopPreserveError = false;
      _pendingStopFinalPhase = null;
      _pendingStopFinalError = null;
      if (!_disposed) {
        notifyListeners();
      }
    }
    if (failure == null) {
      operationCompleter.complete();
    } else {
      operationCompleter.completeError(failure, failureStackTrace);
    }
  }

  void _mergePendingStopOutcome({
    required bool preserveError,
    ConversationPhase? finalPhase,
    String? finalError,
  }) {
    _pendingStopPreserveError =
        _pendingStopPreserveError || preserveError || finalPhase != null;
    if (finalPhase != null) {
      _pendingStopFinalPhase = finalPhase;
    }
    if (finalError != null) {
      _pendingStopFinalError = finalError;
    }
  }

  Future<void> _stopConversationInternal({
    required bool preserveError,
    required bool drainPlayback,
  }) async {
    // Invalidate every producer synchronously before the first await. This is
    // the user-visible stop boundary: no slow playback flush or socket close
    // may allow another microphone frame into the transport.
    _conversationGeneration += 1;
    _cancelReplayState();
    if (!drainPlayback) {
      _invalidatePlaybackOperations();
    }
    if (_diagnosticStartedMicros != null) {
      _diagnosticStoppedMicros ??= _monotonicMicros();
    }
    try {
      _sessions[_activeSpeaker]?.endAudioStream();
    } catch (_) {
      // A broken transport must not prevent local media cleanup.
    }
    _commitTurn(_activeSpeaker);
    _pttActive = false;
    if (!drainPlayback) {
      _clearAllSentencePlayback();
    }
    final StreamSubscription<Uint8List>? captureSubscription =
        _captureSubscription;
    _captureSubscription = null;
    final StreamSubscription<Uint8List>? headsetSubscription =
        _headsetSubscription;
    _headsetSubscription = null;

    // Stop the producers first; playback and the session socket are released
    // after a bounded drain so the final words play out.
    await Future.wait(<Future<void>>[
      _cancelSubscriptionBestEffort(captureSubscription),
      _cancelSubscriptionBestEffort(headsetSubscription),
      _runAuthoritativeCleanup(_audioCapture.stop),
      _runAuthoritativeCleanup(_headsetCapture.stop),
    ]);
    if (drainPlayback) {
      await _drainPlaybackGracefully();
      _clearAllSentencePlayback();
      _invalidatePlaybackOperations();
      await _closeSessionsBestEffort();
      await _runAuthoritativeCleanup(_releasePlayback);
    } else {
      await Future.wait(<Future<void>>[
        _closeSessionsBestEffort(),
        _runAuthoritativeCleanup(_releasePlayback),
      ]);
    }

    final bool effectivePreserveError =
        preserveError || _pendingStopPreserveError;
    final ConversationPhase? effectiveFinalPhase = _pendingStopFinalPhase;
    final String? effectiveFinalError = _pendingStopFinalError;
    if (!effectivePreserveError) {
      _errorMessage = null;
    } else if (effectiveFinalError != null) {
      _errorMessage = effectiveFinalError;
    }
    if (!_disposed) {
      _phase =
          effectiveFinalPhase ??
          (hasApiKey ? ConversationPhase.idle : ConversationPhase.needsKey);
      notifyListeners();
    }
  }

  /// Bounded graceful tail: accept the model's final audio for [tailGraceDuration],
  /// then let the enqueue chain and the native queue play out before teardown.
  /// Every phase is bounded so an explicit stop always completes.
  Future<void> _drainPlaybackGracefully() async {
    _tailGraceActive = true;
    try {
      await Future<void>.delayed(tailGraceDuration);
    } finally {
      _tailGraceActive = false;
    }
    try {
      await _waitForPlayback().timeout(_stopDrainTimeout);
    } catch (_) {
      // A stuck enqueue chain must not delay the authoritative teardown.
    }
    final Stopwatch stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < _stopDrainTimeout) {
      try {
        final PcmPlaybackMetrics metrics = await _playback.metrics();
        if (metrics.pendingPlaybackBytes <= 0) {
          return;
        }
      } catch (_) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  static const Duration _stopDrainTimeout = Duration(seconds: 2);

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
        drainPlayback: false,
        finalPhase: phase,
        finalError: message,
      ),
    );
  }

  void _invalidateApiKeyAfterAuthenticationFailure(String userMessage) {
    if (_disposed || _keyInvalidationOperation != null) {
      return;
    }
    final String detail = userMessage.trim();
    final String message = detail.isEmpty
        ? 'API Key 无效或已失效，请更新 Key 后重试'
        : '$detail；请更新 API Key 后重试';
    _apiKey = '';
    _rememberKey = false;
    _setKeyPersistenceIntent(null);
    _phase = ConversationPhase.needsKey;
    _errorMessage = message;
    if (_diagnosticStartedMicros != null) {
      _diagnosticStoppedMicros ??= _monotonicMicros();
    }
    notifyListeners();

    // Register the invalidation before starting cleanup. A synchronous stream
    // can emit another authentication failure from endAudioStream/close.
    final Completer<void> completer = Completer<void>();
    final Future<void> operation = completer.future;
    _keyInvalidationOperation = operation;
    unawaited(
      _runApiKeyInvalidation(message).whenComplete(() {
        if (identical(_keyInvalidationOperation, operation)) {
          _keyInvalidationOperation = null;
        }
        completer.complete();
      }),
    );
  }

  Future<void> _runApiKeyInvalidation(String message) async {
    final List<Object?> results = await Future.wait<Object?>(<Future<Object?>>[
      _stopConversationWithOutcome(
        preserveError: true,
        drainPlayback: false,
        finalPhase: ConversationPhase.needsKey,
        finalError: message,
      ).then<Object?>((_) => null, onError: (Object _, StackTrace _) => null),
      _deleteInvalidPersistedKey(),
    ]);
    if (results[1] == true || _disposed) {
      return;
    }
    _phase = ConversationPhase.needsKey;
    _errorMessage = '$message；无法清除设备中已保存的旧 Key，请用新 Key 覆盖或清除应用数据';
    notifyListeners();
  }

  Future<bool> _deleteInvalidPersistedKey() async {
    final Future<void> deletion = _keyStore.delete();
    try {
      await deletion.timeout(cleanupTimeout);
      _persistedKeyState = _PersistedKeyState.absent;
      return true;
    } on TimeoutException {
      _persistedKeyState = _PersistedKeyState.unknown;
      // Future.timeout does not cancel secure-storage work. If this delete
      // eventually wins after a replacement Key has been saved, reconcile the
      // latest persistence intent so the stale mutation cannot erase it.
      unawaited(
        deletion.then(
          (_) => _reconcileKeyPersistenceIntent(),
          onError: (Object _, StackTrace _) {},
        ),
      );
      return false;
    } catch (_) {
      // The invalid key is already gone from process memory. A replacement
      // key can still overwrite an undeletable secure-storage copy.
      _persistedKeyState = _PersistedKeyState.unknown;
      return false;
    }
  }

  void _setKeyPersistenceIntent(String? key) {
    _desiredPersistedKey = key;
    _keyPersistenceIntentGeneration += 1;
  }

  Future<void> _reconcileKeyPersistenceIntent() async {
    while (true) {
      final int generation = _keyPersistenceIntentGeneration;
      final String? desiredKey = _desiredPersistedKey;
      try {
        if (desiredKey == null) {
          await _keyStore.delete();
        } else {
          await _keyStore.write(desiredKey);
        }
      } catch (_) {
        if (generation == _keyPersistenceIntentGeneration) {
          _persistedKeyState = _PersistedKeyState.unknown;
          if (!_disposed) {
            _errorMessage = desiredKey == null
                ? '无法确认设备中的 API Key 已清除，请清除应用数据'
                : 'Key 当前可用，但无法确认已安全保存；请重试保存';
            notifyListeners();
          }
          return;
        }
      }
      if (generation != _keyPersistenceIntentGeneration) {
        continue;
      }
      _persistedKeyState = desiredKey == null
          ? _PersistedKeyState.absent
          : _PersistedKeyState.present;
      return;
    }
  }

  Future<void> _closeSessionsBestEffort() async {
    final List<StreamSubscription<LiveEvent>> subscriptions =
        _sessionSubscriptions.values.toList(growable: false);
    _sessionSubscriptions.clear();
    final List<LiveTranslationSession> sessions = _sessions.values.toList(
      growable: false,
    );
    _sessions.clear();
    await Future.wait(<Future<void>>[
      for (final StreamSubscription<LiveEvent> subscription in subscriptions)
        _cancelSubscriptionBestEffort(subscription),
      for (final LiveTranslationSession session in sessions)
        _runCleanupBestEffort(session.close),
    ]);
  }

  Future<void> _cancelSubscriptionBestEffort<T>(
    StreamSubscription<T>? subscription,
  ) async {
    try {
      await subscription?.cancel().timeout(cleanupTimeout);
    } catch (_) {
      // Continue releasing independent resources after a callback race.
    }
  }

  Future<void> _runCleanupBestEffort(Future<void> Function() operation) async {
    try {
      await operation().timeout(cleanupTimeout);
    } catch (_) {
      // Cleanup is intentionally independent: one failed adapter or transport
      // must never leave the remaining recorder, sessions, or player alive.
    }
  }

  Future<void> _runAuthoritativeCleanup(
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (_) {
      // Media owners cannot be safely reused while an old stop/dispose is
      // still running. Wait for completion, but isolate a terminal failure so
      // the other independent cleanup owners still settle.
    }
  }

  Future<void> _releasePlayback() {
    final Future<void>? existing = _playbackDisposalOperation;
    if (existing != null) {
      return existing;
    }
    late final Future<void> operation;
    operation = _releasePlaybackNow().whenComplete(() {
      if (identical(_playbackDisposalOperation, operation)) {
        _playbackDisposalOperation = null;
      }
    });
    _playbackDisposalOperation = operation;
    return operation;
  }

  Future<void> _releasePlaybackNow() async {
    try {
      await _playback.dispose();
    } catch (error) {
      _handlePlaybackFailure(reason: error.toString());
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
      mode: _diagnosticMode,
      sessionDurationMilliseconds: durationMilliseconds,
      microphoneChunksSent: _microphoneChunksSent,
      microphoneChunksSuppressed: _microphoneChunksSuppressed,
      microphoneChunksHeld: _microphoneChunksHeld,
      utterancesDetected: _utterancesDetected,
      bargeIns: _bargeIns,
      sentenceTurnsCompleted: _sentenceTurnsCompleted,
      autoDirectionSwitches: _autoDirectionSwitches,
      headsetState: _headsetState.name,
      outputAudioChunks: _outputAudioChunks,
      outputAudioBytes: _outputAudioBytes,
      completedTurns: _diagnosticCompletedTurns,
      directionSwitches: _directionSwitches,
      reconnectEvents: _reconnectEvents,
      sessionFailures: _sessionFailures,
      playbackFailures: _playbackFailures,
      lastPlaybackFailureReason: _lastPlaybackFailureReason,
      lastPlaybackFailurePlatformCode: _lastPlaybackFailurePlatformCode,
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
    _microphoneChunksHeld = 0;
    _utterancesDetected = 0;
    _bargeIns = 0;
    _playbackAutoRecoveries = 0;
    _sentenceTurnsCompleted = 0;
    _autoDirectionSwitches = 0;
    _outputAudioChunks = 0;
    _outputAudioBytes = 0;
    _diagnosticCompletedTurns = 0;
    _directionSwitches = 0;
    _reconnectEvents = 0;
    _sessionFailures = 0;
    _playbackFailures = 0;
    _lastPlaybackFailureReason = null;
    _lastPlaybackFailurePlatformCode = null;
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
      await _runAuthoritativeCleanup(() => stopOperation);
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
    try {
      await _headsetSubscription?.cancel();
    } catch (_) {
      // Continue releasing the remaining resources.
    } finally {
      _headsetSubscription = null;
    }
    await _runAuthoritativeCleanup(_audioCapture.dispose);
    await _runAuthoritativeCleanup(_headsetCapture.dispose);
    await _closeSessionsBestEffort();
    await _runCleanupBestEffort(_flushPlayback);
    await _runAuthoritativeCleanup(_releasePlayback);
  }
}
