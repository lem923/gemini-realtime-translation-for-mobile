import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'gemini_live_protocol.dart';
import 'live_event.dart';

abstract interface class LiveTranslationSession {
  Stream<LiveEvent> get events;
  bool get isReady;
  Future<void> connect();
  void sendAudio(Uint8List pcm);
  void endAudioStream();
  Future<void> close();
}

typedef LiveSessionFactory =
    LiveTranslationSession Function({
      required String apiKey,
      required String targetLanguageCode,
    });

class GeminiLiveSession implements LiveTranslationSession {
  GeminiLiveSession({
    required this.apiKey,
    required this.targetLanguageCode,
    this.model = GeminiLiveProtocol.model,
    this.translationEnabled = true,
    this.slidingWindowTargetTokens,
    this.compressionTriggerTokens,
    this.asrMinimalSetup = false,
    Uri? endpoint,
    HttpClient Function()? httpClientFactory,
    WebSocketChannel Function(Uri uri, HttpClient client)? channelFactory,
  }) : endpoint =
           endpoint ??
           (_debugEndpointOverride ?? Uri.parse(GeminiLiveProtocol.endpoint)),
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _channelFactory = channelFactory ?? _connectChannel;

  static final Uri? _debugEndpointOverride = _readDebugEndpointOverride();

  static Uri? _readDebugEndpointOverride() {
    const String override = String.fromEnvironment('LIVE_ENDPOINT');
    if (override.isEmpty) {
      return null;
    }
    return Uri.tryParse(override);
  }

  final String apiKey;
  final String targetLanguageCode;
  final String model;
  final bool translationEnabled;
  final bool asrMinimalSetup;
  final int? slidingWindowTargetTokens;
  final int? compressionTriggerTokens;
  final Uri endpoint;
  final HttpClient Function() _httpClientFactory;
  final WebSocketChannel Function(Uri uri, HttpClient client) _channelFactory;
  static const Duration _cleanupTimeout = Duration(milliseconds: 250);
  final StreamController<LiveEvent> _events =
      StreamController<LiveEvent>.broadcast();

  WebSocketChannel? _channel;
  HttpClient? _httpClient;
  // The subscription is cancelled on replacement and close.
  // ignore: cancel_subscriptions
  StreamSubscription<Object?>? _subscription;
  Completer<void>? _setupCompleter;
  Timer? _reconnectTimer;
  Future<void>? _connectOperation;
  Future<void>? _closeOperation;
  String? _resumptionHandle;
  int _generation = 0;
  int _reconnectAttempt = 0;
  bool _disposed = false;
  bool _ready = false;

  @override
  Stream<LiveEvent> get events => _events.stream;

  @override
  bool get isReady => _ready;

  @override
  Future<void> connect() {
    if (_disposed) {
      return Future<void>.error(StateError('Session is closed'));
    }
    final Future<void>? inFlight = _connectOperation;
    if (inFlight != null) {
      return inFlight;
    }
    final Future<void> operation = _connectInternal();
    _connectOperation = operation;
    return operation.whenComplete(() {
      if (identical(_connectOperation, operation)) {
        _connectOperation = null;
      }
    });
  }

  Future<void> _connectInternal() async {
    _reconnectTimer?.cancel();
    _ready = false;
    final int generation = ++_generation;
    // Reconnect scheduling announces the phase immediately, before backoff.
    // Do not announce it again when the timer starts the actual connection.
    if (_reconnectAttempt == 0) {
      _events.add(const LivePhaseChanged(LiveSessionPhase.connecting));
    }
    await _replaceChannel(generation);
    if (_disposed || generation != _generation) {
      return;
    }
    final HttpClient httpClient = _httpClientFactory()
      ..findProxy = _findProxyForWebSocket;
    _httpClient = httpClient;
    final WebSocketChannel channel = _channelFactory(
      endpoint.replace(queryParameters: <String, String>{'key': apiKey}),
      httpClient,
    );
    _channel = channel;
    final Completer<void> setupCompleter = Completer<void>();
    _setupCompleter = setupCompleter;
    final Future<void> setupFuture = setupCompleter.future;
    // The socket can close while `channel.ready` is still pending. Attach an
    // error observer immediately so that completing the setup future in that
    // window is not reported as an unhandled asynchronous error. The original
    // future remains erroneous and is still awaited below by the state machine.
    unawaited(setupFuture.catchError((Object _) {}));
    _subscription = channel.stream.listen(
      (Object? data) => _handlePayload(data, generation),
      onError: (Object error, StackTrace stackTrace) {
        _handleTransportFailure(generation);
      },
      onDone: () => _handleClosed(generation, channel.closeCode),
      cancelOnError: false,
    );

    try {
      await channel.ready.timeout(const Duration(seconds: 15));
      if (_disposed || generation != _generation) {
        return;
      }
      if (asrMinimalSetup) {
        channel.sink.add(GeminiLiveProtocol.asrSetupMessage(model: model));
      } else {
        channel.sink.add(
          GeminiLiveProtocol.setupMessage(
            targetLanguageCode: targetLanguageCode,
            resumptionHandle: _resumptionHandle,
            slidingWindowTargetTokens: slidingWindowTargetTokens,
            compressionTriggerTokens: compressionTriggerTokens,
            model: model,
            translationEnabled: translationEnabled,
          ),
        );
      }
      await setupFuture.timeout(const Duration(seconds: 15));
      _reconnectAttempt = 0;
    } on TimeoutException {
      if (_disposed || generation != _generation) {
        return;
      }
      _emitFailure(
        '连接 Gemini 超时，请检查网络后重试',
        retryable: _reconnectAttempt > 0,
        kind: LiveFailureKind.offline,
      );
      await _discardChannel(generation);
      _continueReconnectIfNeeded();
      rethrow;
    } on SocketException {
      if (_disposed || generation != _generation) {
        return;
      }
      _emitFailure(
        '无法连接 Gemini，请检查网络',
        retryable: _reconnectAttempt > 0,
        kind: LiveFailureKind.offline,
      );
      await _discardChannel(generation);
      _continueReconnectIfNeeded();
      rethrow;
    } on WebSocketChannelException {
      if (_disposed || generation != _generation) {
        return;
      }
      _emitFailure(
        '无法建立 Gemini Live 会话',
        retryable: _reconnectAttempt > 0,
        kind: LiveFailureKind.offline,
      );
      await _discardChannel(generation);
      _continueReconnectIfNeeded();
      rethrow;
    } on _SessionRejected catch (rejection) {
      if (_disposed || generation != _generation) {
        return;
      }
      await _discardChannel(generation);
      if (rejection.retryable) {
        _continueReconnectIfNeeded();
      }
      rethrow;
    } catch (_) {
      if (_disposed || generation != _generation) {
        return;
      }
      _emitFailure(
        '无法建立 Gemini Live 会话',
        retryable: _reconnectAttempt > 0,
        kind: LiveFailureKind.service,
      );
      await _discardChannel(generation);
      _continueReconnectIfNeeded();
      rethrow;
    }
  }

  void _continueReconnectIfNeeded() {
    if (_reconnectAttempt > 0 && !_disposed) {
      _scheduleReconnect();
    }
  }

  static String _findProxyForWebSocket(Uri uri) {
    const String buildProxy = String.fromEnvironment('LIVE_PROXY');
    if (buildProxy.isNotEmpty) {
      return 'PROXY $buildProxy';
    }
    final Uri proxyLookupUri = uri.replace(
      scheme: uri.scheme == 'wss' ? 'https' : 'http',
    );
    return HttpClient.findProxyFromEnvironment(proxyLookupUri);
  }

  static WebSocketChannel _connectChannel(Uri uri, HttpClient client) {
    return IOWebSocketChannel.connect(
      uri,
      pingInterval: const Duration(seconds: 20),
      connectTimeout: const Duration(seconds: 15),
      customClient: client,
    );
  }

  Future<void> _discardChannel(int generation) async {
    if (generation != _generation) {
      return;
    }
    _generation += 1;
    await _replaceChannel(_generation);
  }

  Future<void> _replaceChannel(int generation) async {
    final StreamSubscription<Object?>? subscription = _subscription;
    _subscription = null;
    final WebSocketChannel? channel = _channel;
    _channel = null;
    final HttpClient? httpClient = _httpClient;
    _httpClient = null;
    if (generation == _generation) {
      _setupCompleter = null;
    }
    try {
      httpClient?.close(force: true);
    } catch (_) {
      // Ownership is already detached; continue settling the other resources.
    }

    await Future.wait<void>(<Future<void>>[
      if (subscription != null)
        _settleCleanup(() async {
          await subscription.cancel();
        }),
      if (channel != null)
        _settleCleanup(() async {
          // `dart:io` does not allow a client to send the server-only 1001
          // Going Away code. A Gemini connection can itself finish with 1001;
          // normalise our local replacement close to 1000 so reconnect remains
          // valid even when the old channel has already observed that code.
          await channel.sink.close(status.normalClosure);
        }),
    ]);
  }

  Future<void> _settleCleanup(Future<void> Function() cleanup) async {
    try {
      await Future<void>.sync(cleanup).timeout(_cleanupTimeout);
    } catch (_) {
      // Ownership has already been cleared and the HttpClient force-closed.
      // A broken adapter must not strand reconnect or session shutdown.
    }
  }

  void _handlePayload(Object? data, int generation) {
    if (_disposed || generation != _generation) {
      return;
    }
    final String? payload = _decodePayload(data);
    if (payload == null) {
      return;
    }
    for (final LiveEvent event in GeminiLiveProtocol.parseServerMessage(
      payload,
    )) {
      switch (event) {
        case LivePhaseChanged(:final LiveSessionPhase phase)
            when phase == LiveSessionPhase.ready:
          _ready = true;
          final Completer<void>? completer = _setupCompleter;
          if (completer != null && !completer.isCompleted) {
            completer.complete();
          }
        case LiveResumptionHandle(:final String handle):
          _resumptionHandle = handle;
        case LiveGoAway():
          _scheduleReconnect(immediate: true);
        case LiveSessionFailure(
          :final bool authenticationFailure,
          :final bool retryable,
        ):
          _ready = false;
          final Completer<void>? completer = _setupCompleter;
          if (completer != null && !completer.isCompleted) {
            completer.completeError(
              _SessionRejected(
                authenticationFailure: authenticationFailure,
                retryable: retryable,
              ),
            );
          }
          if (retryable) {
            _scheduleReconnect();
          }
        default:
          break;
      }
      _events.add(event);
    }
  }

  static String? _decodePayload(Object? data) {
    if (data is String) {
      return data;
    }
    if (data is List<int>) {
      return utf8.decode(data, allowMalformed: true);
    }
    return null;
  }

  void _handleTransportFailure(int generation) {
    if (_disposed || generation != _generation) {
      return;
    }
    _ready = false;
    _failPendingSetup();
    _emitFailure(
      '网络连接中断，恢复后将自动重连',
      retryable: true,
      kind: LiveFailureKind.offline,
    );
    _scheduleReconnect();
  }

  void _handleClosed(int generation, int? closeCode) {
    if (_disposed || generation != _generation) {
      return;
    }
    _ready = false;
    if (closeCode == status.policyViolation) {
      const LiveSessionFailure failure = LiveSessionFailure(
        userMessage: 'API Key、模型权限或会话配置无效',
        authenticationFailure: true,
        retryable: false,
        kind: LiveFailureKind.authentication,
      );
      _failPendingSetup(
        const _SessionRejected(authenticationFailure: true, retryable: false),
      );
      _events.add(failure);
      return;
    }
    _failPendingSetup();
    _scheduleReconnect();
  }

  void _failPendingSetup([Object? error]) {
    final Completer<void>? completer = _setupCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        error ?? StateError('Gemini session closed during setup'),
      );
    }
  }

  void _scheduleReconnect({bool immediate = false}) {
    if (_disposed || _reconnectTimer?.isActive == true) {
      return;
    }
    if (_reconnectAttempt >= 5) {
      _events.add(
        const LiveSessionFailure(
          userMessage: '多次重连失败，请停止后重新开始',
          authenticationFailure: false,
          retryable: false,
          kind: LiveFailureKind.offline,
        ),
      );
      return;
    }
    _reconnectAttempt += 1;
    _events.add(const LivePhaseChanged(LiveSessionPhase.reconnecting));
    final Duration delay = immediate
        ? Duration.zero
        : Duration(seconds: 1 << (_reconnectAttempt - 1).clamp(0, 4));
    _reconnectTimer = Timer(delay, () {
      unawaited(connect().catchError((Object _) {}));
    });
  }

  void _emitFailure(
    String message, {
    required bool retryable,
    required LiveFailureKind kind,
  }) {
    if (_disposed || _events.isClosed) {
      return;
    }
    _events.add(
      LiveSessionFailure(
        userMessage: message,
        authenticationFailure: false,
        retryable: retryable,
        kind: kind,
      ),
    );
  }

  @override
  void sendAudio(Uint8List pcm) {
    if (!_ready || _disposed || pcm.isEmpty) {
      return;
    }
    _channel?.sink.add(GeminiLiveProtocol.audioMessage(pcm));
  }

  @override
  void endAudioStream() {
    if (!_ready || _disposed) {
      return;
    }
    _channel?.sink.add(GeminiLiveProtocol.audioStreamEndMessage());
  }

  @override
  Future<void> close() {
    final Future<void>? inFlight = _closeOperation;
    if (inFlight != null) {
      return inFlight;
    }
    final Future<void> operation = _closeInternal();
    _closeOperation = operation;
    return operation;
  }

  Future<void> _closeInternal() async {
    _disposed = true;
    _ready = false;
    _generation += 1;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final Completer<void>? setupCompleter = _setupCompleter;
    _setupCompleter = null;
    if (setupCompleter != null && !setupCompleter.isCompleted) {
      setupCompleter.completeError(StateError('Gemini session was closed'));
    }
    await _replaceChannel(_generation);
    if (!_events.isClosed) {
      _events.add(const LivePhaseChanged(LiveSessionPhase.closed));
      await _events.close();
    }
  }
}

class _SessionRejected implements Exception {
  const _SessionRejected({
    required this.authenticationFailure,
    required this.retryable,
  });

  final bool authenticationFailure;
  final bool retryable;
}
