import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_translation/audio/audio_capture_gateway.dart';
import 'package:realtime_translation/audio/pcm_playback_gateway.dart';
import 'package:realtime_translation/conversation/conversation_controller.dart';
import 'package:realtime_translation/live_translate/live_event.dart';
import 'package:realtime_translation/live_translate/live_translation_session.dart';
import 'package:realtime_translation/security/api_key_store.dart';
import 'package:realtime_translation/ui/conversation_page.dart';

void main() {
  testWidgets('switches layouts and selects a searchable language', (
    WidgetTester tester,
  ) async {
    final ConversationController controller = ConversationController(
      keyStore: _StoredKeyStore(),
      audioCapture: _NoopAudioCapture(),
      playback: _NoopPlayback(),
      sessionFactory:
          ({required String apiKey, required String targetLanguageCode}) =>
              _NoopLiveSession(),
    );
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(home: ConversationPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('准备就绪'), findsOneWidget);
    expect(find.text('简体中文'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);

    await tester.tap(find.byTooltip('面对面模式'));
    await tester.pumpAndSettle();
    expect(find.text('点击这里，让 简体中文 讲话'), findsOneWidget);
    expect(find.byTooltip('标准对话模式'), findsOneWidget);

    await tester.tap(find.byTooltip('标准对话模式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('简体中文'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ja');
    await tester.pumpAndSettle();
    expect(find.text('日本語'), findsOneWidget);
    await tester.tap(find.text('日本語'));
    await tester.pumpAndSettle();
    expect(find.text('日本語'), findsOneWidget);
    expect(controller.languageA.code, 'ja');

    controller.dispose();
  });
}

class _StoredKeyStore implements ApiKeyStore {
  @override
  Future<void> delete() async {}

  @override
  Future<String?> read() async => 'stored-key';

  @override
  Future<void> write(String value) async {}
}

class _NoopAudioCapture implements AudioCaptureGateway {
  @override
  Future<void> dispose() async {}

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<Uint8List>> start() async => const Stream<Uint8List>.empty();

  @override
  Future<void> stop() async {}
}

class _NoopPlayback implements PcmPlaybackGateway {
  @override
  Future<void> configure() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> enqueue(Uint8List pcm) async {}

  @override
  Future<void> flush() async {}
}

class _NoopLiveSession implements LiveTranslationSession {
  final StreamController<LiveEvent> _events =
      StreamController<LiveEvent>.broadcast();

  @override
  Future<void> close() => _events.close();

  @override
  Future<void> connect() async {}

  @override
  Stream<LiveEvent> get events => _events.stream;

  @override
  bool get isReady => true;

  @override
  void sendAudio(Uint8List pcm) {}
}
