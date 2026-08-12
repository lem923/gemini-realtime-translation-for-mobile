import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_translation/live_translate/live_event.dart';
import 'package:realtime_translation/live_translate/live_translation_session.dart';

void main() {
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
}
