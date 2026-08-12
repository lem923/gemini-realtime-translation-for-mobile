import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
}
