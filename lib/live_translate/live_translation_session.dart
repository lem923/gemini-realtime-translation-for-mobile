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
  Future<void> close();
}

typedef LiveSessionFactory =
    LiveTranslationSession Function({
      required String apiKey,
      required String targetLanguageCode,
    });

class GeminiLiveSession implements LiveTranslationSession {
  GeminiLiveSession({required this.apiKey, required this.targetLanguageCode});

  final String apiKey;
  final String targetLanguageCode;
  final StreamController<LiveEvent> _events =
      StreamController<LiveEvent>.broadcast();

  IOWebSocketChannel? _channel;
  HttpClient? _httpClient;
  // The subscription is cancelled on replacement and close.
  // ignore: cancel_subscriptions
  StreamSubscription<Object?>? _subscription;
  Completer<void>? _setupCompleter;
  Timer? _reconnectTimer;
  Future<void>? _connectOperation;
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
    _events.add(
      LivePhaseChanged(
        _reconnectAttempt == 0
            ? LiveSessionPhase.connecting
            : LiveSessionPhase.reconnecting,
      ),
    );
    await _replaceChannel(generation);
    if (_disposed || generation != _generation) {
      return;
    }
    final HttpClient httpClient = HttpClient()
      ..findProxy = _findProxyForWebSocket;
    _httpClient = httpClient;
    final IOWebSocketChannel channel = IOWebSocketChannel.connect(
      Uri.parse(
        GeminiLiveProtocol.endpoint,
      ).replace(queryParameters: <String, String>{'key': apiKey}),
      pingInterval: const Duration(seconds: 20),
      connectTimeout: const Duration(seconds: 15),
      customClient: httpClient,
    );
    _channel = channel;
    final Completer<void> setupCompleter = Completer<void>();
    _setupCompleter = setupCompleter;
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
      channel.sink.add(
        GeminiLiveProtocol.setupMessage(
          targetLanguageCode: targetLanguageCode,
          resumptionHandle: _resumptionHandle,
        ),
      );
      await setupCompleter.future.timeout(const Duration(seconds: 15));
      _reconnectAttempt = 0;
    } on TimeoutException {
      _emitFailure('连接 Gemini 超时，请检查网络后重试');
      await _discardChannel(generation);
      rethrow;
    } on SocketException {
      _emitFailure('无法连接 Gemini，请检查网络');
      await _discardChannel(generation);
      rethrow;
    } on WebSocketChannelException {
      _emitFailure('无法建立 Gemini Live 会话');
      await _discardChannel(generation);
      rethrow;
    } catch (_) {
      _emitFailure('无法建立 Gemini Live 会话');
      await _discardChannel(generation);
      rethrow;
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
    await subscription?.cancel();
    final IOWebSocketChannel? channel = _channel;
    _channel = null;
    _httpClient?.close(force: true);
    _httpClient = null;
    if (channel != null) {
      await channel.sink.close(status.goingAway).catchError((Object _) {});
    }
    if (generation == _generation) {
      _setupCompleter = null;
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
        case LiveSessionFailure(:final bool authenticationFailure):
          _ready = false;
          final Completer<void>? completer = _setupCompleter;
          if (completer != null && !completer.isCompleted) {
            completer.completeError(StateError('Gemini session rejected'));
          }
          if (!authenticationFailure) {
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
    _emitFailure('Gemini Live 连接中断，正在重连');
    _scheduleReconnect();
  }

  void _handleClosed(int generation, int? closeCode) {
    if (_disposed || generation != _generation) {
      return;
    }
    _ready = false;
    _failPendingSetup();
    if (closeCode == status.policyViolation) {
      _events.add(
        const LiveSessionFailure(
          userMessage: 'API Key、模型权限或会话配置无效',
          authenticationFailure: true,
        ),
      );
      return;
    }
    _scheduleReconnect();
  }

  void _failPendingSetup() {
    final Completer<void>? completer = _setupCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError('Gemini session closed during setup'));
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

  void _emitFailure(String message) {
    _events.add(
      LiveSessionFailure(userMessage: message, authenticationFailure: false),
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
  Future<void> close() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _ready = false;
    _generation += 1;
    _reconnectTimer?.cancel();
    final StreamSubscription<Object?>? subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    final IOWebSocketChannel? channel = _channel;
    _channel = null;
    if (channel != null) {
      await channel.sink.close(status.normalClosure);
    }
    _httpClient?.close(force: true);
    _httpClient = null;
    _events.add(const LivePhaseChanged(LiveSessionPhase.closed));
    await _events.close();
  }
}
