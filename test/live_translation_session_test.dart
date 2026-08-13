import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_translation/live_translate/live_event.dart';
import 'package:realtime_translation/live_translate/live_translation_session.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test(
    'closing during setup cancels connect without an unhandled error',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final Completer<void> setupReceived = Completer<void>();
      final Future<void> serverTask = () async {
        final HttpRequest request = await server.first;
        final WebSocket socket = await WebSocketTransformer.upgrade(request);
        try {
          await for (final Object? _ in socket) {
            if (!setupReceived.isCompleted) {
              setupReceived.complete();
            }
          }
        } finally {
          await socket.close();
        }
      }();
      final GeminiLiveSession session = GeminiLiveSession(
        apiKey: 'local-test-key',
        targetLanguageCode: 'zh-Hans',
        endpoint: Uri.parse(
          'ws://${server.address.address}:${server.port}/live',
        ),
      );
      final List<Object> unhandledErrors = <Object>[];
      final Completer<void> zoneComplete = Completer<void>();

      unawaited(
        runZonedGuarded(
          () async {
            final Future<void> connecting = session.connect();
            await setupReceived.future.timeout(const Duration(seconds: 2));
            await session.close().timeout(const Duration(seconds: 1));
            await connecting.timeout(const Duration(seconds: 1));
            await Future<void>.delayed(const Duration(milliseconds: 20));
            zoneComplete.complete();
          },
          (Object error, StackTrace stackTrace) {
            unhandledErrors.add(error);
            if (!zoneComplete.isCompleted) {
              zoneComplete.complete();
            }
          },
        ),
      );

      await zoneComplete.future.timeout(const Duration(seconds: 5));
      await serverTask.timeout(const Duration(seconds: 2));
      await server.close(force: true);
      expect(unhandledErrors, isEmpty);
    },
  );

  test(
    'setup close is reported to connect without an unhandled future',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final Future<void> serverTask = () async {
        final HttpRequest request = await server.first;
        final WebSocket socket = await WebSocketTransformer.upgrade(request);
        await socket.close(WebSocketStatus.goingAway);
      }();
      final GeminiLiveSession session = GeminiLiveSession(
        apiKey: 'local-test-key',
        targetLanguageCode: 'zh-Hans',
        endpoint: Uri.parse(
          'ws://${server.address.address}:${server.port}/live',
        ),
      );
      final List<Object> unhandledErrors = <Object>[];
      final Completer<void> zoneComplete = Completer<void>();

      unawaited(
        runZonedGuarded(
          () async {
            await expectLater(session.connect(), throwsA(isA<Object>()));
            await session.close();
            await Future<void>.delayed(const Duration(milliseconds: 20));
            zoneComplete.complete();
          },
          (Object error, StackTrace stackTrace) {
            unhandledErrors.add(error);
            if (!zoneComplete.isCompleted) {
              zoneComplete.complete();
            }
          },
        ),
      );

      await zoneComplete.future.timeout(const Duration(seconds: 5));
      await serverTask;
      await server.close(force: true);
      expect(unhandledErrors, isEmpty);
    },
  );

  test(
    'server going-away close reconnects without an unhandled error',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final List<WebSocket> sockets = <WebSocket>[];
      var connectionCount = 0;
      final StreamSubscription<HttpRequest> serverSubscription = server.listen((
        HttpRequest request,
      ) async {
        final WebSocket socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        connectionCount += 1;
        final int connectionNumber = connectionCount;
        socket.listen((Object? _) async {
          socket.add('{"setupComplete": {}}');
          if (connectionNumber == 1) {
            await socket.close(WebSocketStatus.goingAway);
          }
        });
      });
      final GeminiLiveSession session = GeminiLiveSession(
        apiKey: 'local-test-key',
        targetLanguageCode: 'zh-Hans',
        endpoint: Uri.parse(
          'ws://${server.address.address}:${server.port}/live',
        ),
      );
      final List<Object> unhandledErrors = <Object>[];
      final Completer<void> reconnected = Completer<void>();
      final Completer<void> zoneComplete = Completer<void>();

      unawaited(
        runZonedGuarded(
          () async {
            var readyEvents = 0;
            var reconnectEvents = 0;
            final StreamSubscription<Object?> eventSubscription = session.events
                .listen((Object? event) {
                  if (event case LivePhaseChanged(
                    phase: LiveSessionPhase.ready,
                  )) {
                    readyEvents += 1;
                    if (readyEvents == 2 && !reconnected.isCompleted) {
                      reconnected.complete();
                    }
                  } else if (event case LivePhaseChanged(
                    phase: LiveSessionPhase.reconnecting,
                  )) {
                    reconnectEvents += 1;
                  }
                });
            await session.connect();
            await reconnected.future.timeout(const Duration(seconds: 5));
            expect(reconnectEvents, 1);
            await session.close();
            await eventSubscription.cancel();
            await Future<void>.delayed(const Duration(milliseconds: 20));
            zoneComplete.complete();
          },
          (Object error, StackTrace stackTrace) {
            unhandledErrors.add(error);
            if (!zoneComplete.isCompleted) {
              zoneComplete.complete();
            }
          },
        ),
      );

      await zoneComplete.future.timeout(const Duration(seconds: 10));
      for (final WebSocket socket in sockets) {
        await socket.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
      expect(connectionCount, 2);
      expect(unhandledErrors, isEmpty);
    },
  );

  test('reconnect survives cleanup futures that never complete', () async {
    final List<_TrackingHttpClient> clients = <_TrackingHttpClient>[];
    final List<_TestWebSocketChannel> channels = <_TestWebSocketChannel>[];
    final Completer<void> reconnected = Completer<void>();
    final GeminiLiveSession session = GeminiLiveSession(
      apiKey: 'local-test-key',
      targetLanguageCode: 'zh-Hans',
      httpClientFactory: () {
        final _TrackingHttpClient client = _TrackingHttpClient();
        clients.add(client);
        return client;
      },
      channelFactory: (Uri _, HttpClient _) {
        final _TestWebSocketChannel channel = _TestWebSocketChannel(
          cleanupMode: channels.isEmpty
              ? _CleanupMode.hang
              : _CleanupMode.complete,
        );
        channels.add(channel);
        return channel;
      },
    );
    final StreamSubscription<LiveEvent> events = session.events.listen((
      LiveEvent event,
    ) {
      if (event case LivePhaseChanged(
        phase: LiveSessionPhase.ready,
      ) when channels.length == 2 && !reconnected.isCompleted) {
        reconnected.complete();
      }
    });

    await session.connect();
    channels.single.add(<String, Object?>{'goAway': <String, Object?>{}});
    await _waitUntil(() => clients.first.forceClosed);
    await reconnected.future.timeout(const Duration(seconds: 1));

    expect(channels, hasLength(2));
    expect(clients, hasLength(2));
    expect(clients.first.forceClosed, isTrue);
    await session.close().timeout(const Duration(seconds: 1));
    await events.cancel();
    for (final _TestWebSocketChannel channel in channels) {
      await channel.dispose();
    }
  });

  test('concurrent close coalesces and isolates cleanup failures', () async {
    final _TrackingHttpClient client = _TrackingHttpClient();
    final _TestWebSocketChannel channel = _TestWebSocketChannel(
      cleanupMode: _CleanupMode.throwError,
    );
    final GeminiLiveSession session = GeminiLiveSession(
      apiKey: 'local-test-key',
      targetLanguageCode: 'zh-Hans',
      httpClientFactory: () => client,
      channelFactory: (Uri _, HttpClient _) => channel,
    );
    final List<LiveEvent> events = <LiveEvent>[];
    final StreamSubscription<LiveEvent> eventSubscription = session.events
        .listen(events.add);

    await session.connect();
    final Future<void> firstClose = session.close();
    final Future<void> secondClose = session.close();

    expect(identical(firstClose, secondClose), isTrue);
    expect(client.forceClosed, isTrue);
    await firstClose.timeout(const Duration(seconds: 1));
    expect(
      events.whereType<LivePhaseChanged>().where(
        (LivePhaseChanged event) => event.phase == LiveSessionPhase.closed,
      ),
      hasLength(1),
    );
    await eventSubscription.cancel();
    await channel.dispose();
  });
}

enum _CleanupMode { complete, hang, throwError }

class _TrackingHttpClient implements HttpClient {
  bool forceClosed = false;

  @override
  set findProxy(String Function(Uri url)? value) {}

  @override
  void close({bool force = false}) {
    forceClosed = force;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestWebSocketChannel implements WebSocketChannel {
  _TestWebSocketChannel({required this.cleanupMode})
    : _controller = StreamController<Object?>.broadcast(),
      _sink = _TestWebSocketSink(cleanupMode) {
    _sink.onAdd = (Object? data) {
      if (!_controller.isClosed && data is String && data.contains('"setup"')) {
        scheduleMicrotask(() {
          if (!_controller.isClosed) {
            _controller.add('{"setupComplete": {}}');
          }
        });
      }
    };
  }

  final _CleanupMode cleanupMode;
  final StreamController<Object?> _controller;
  final _TestWebSocketSink _sink;

  void add(Map<String, Object?> message) {
    _controller.add(jsonEncode(message));
  }

  Future<void> dispose() async {
    await _controller.close();
  }

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  WebSocketSink get sink => _sink;

  @override
  Stream<Object?> get stream =>
      _CleanupStream<Object?>(_controller.stream, cleanupMode);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CleanupStream<T> extends Stream<T> {
  const _CleanupStream(this._delegate, this._cleanupMode);

  final Stream<T> _delegate;
  final _CleanupMode _cleanupMode;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _CleanupSubscription<T>(
      _delegate.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      ),
      _cleanupMode,
    );
  }
}

class _CleanupSubscription<T> implements StreamSubscription<T> {
  _CleanupSubscription(this._delegate, this._cleanupMode);

  final StreamSubscription<T> _delegate;
  final _CleanupMode _cleanupMode;

  @override
  Future<void> cancel() {
    return switch (_cleanupMode) {
      _CleanupMode.complete => _delegate.cancel(),
      _CleanupMode.hang => Completer<void>().future,
      _CleanupMode.throwError => Future<void>.error(
        StateError('cancel failed'),
      ),
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestWebSocketSink implements WebSocketSink {
  _TestWebSocketSink(this.cleanupMode);

  final _CleanupMode cleanupMode;
  void Function(Object? data)? onAdd;

  @override
  void add(Object? data) => onAdd?.call(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    return switch (cleanupMode) {
      _CleanupMode.complete => Future<void>.value(),
      _CleanupMode.hang => Completer<void>().future,
      _CleanupMode.throwError => Future<void>.error(StateError('close failed')),
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw TimeoutException('condition not reached');
}
