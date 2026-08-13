import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_translation/audio/audio_capture_gateway.dart';
import 'package:realtime_translation/audio/pcm_playback_gateway.dart';
import 'package:realtime_translation/conversation/conversation_controller.dart';
import 'package:realtime_translation/conversation/conversation_models.dart';
import 'package:realtime_translation/live_translate/live_event.dart';
import 'package:realtime_translation/live_translate/live_translation_session.dart';
import 'package:realtime_translation/permissions/microphone_permission_gateway.dart';
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
    expect(find.text('点击这里，用 简体中文 讲话'), findsOneWidget);
    expect(find.text('等待 English 译文'), findsOneWidget);
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

  testWidgets('speaker card body selects speaker, pill opens language picker', (
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
    expect(controller.activeSpeaker, SpeakerSide.a);

    final Size pillSize = tester.getSize(
      find.bySemanticsLabel(RegExp('更换语言 English')),
    );
    expect(pillSize.height, greaterThanOrEqualTo(48));

    await tester.tap(find.bySemanticsLabel(RegExp('讲话人 B')));
    await tester.pumpAndSettle();
    expect(controller.activeSpeaker, SpeakerSide.b);

    await tester.tap(find.text('简体中文'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    controller.dispose();
  });

  testWidgets('shows connecting state in face-to-face mode', (
    WidgetTester tester,
  ) async {
    final _GatedLiveSession session = _GatedLiveSession();
    final ConversationController controller = ConversationController(
      keyStore: _StoredKeyStore(),
      audioCapture: _NoopAudioCapture(),
      playback: _NoopPlayback(),
      sessionFactory:
          ({required String apiKey, required String targetLanguageCode}) =>
              session,
    );
    await controller.initialize();
    final Future<void> start = controller.startConversation();
    await tester.pumpWidget(
      MaterialApp(home: ConversationPage(controller: controller)),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('面对面模式'));
    await tester.pump();

    expect(find.text('正在连接'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('正在连接')),
      matchesSemantics(label: '翻译状态：正在连接', isLiveRegion: true),
    );

    session.releaseConnection();
    await start;
    await tester.pump();
    controller.dispose();
  });

  testWidgets('shows failure states and messages in face-to-face mode', (
    WidgetTester tester,
  ) async {
    final cases =
        <
          ({
            LiveFailureKind kind,
            bool retryable,
            String status,
            String message,
          })
        >[
          (
            kind: LiveFailureKind.offline,
            retryable: true,
            status: '网络不可用，等待恢复',
            message: '网络连接中断，恢复后将自动重连',
          ),
          (
            kind: LiveFailureKind.rateLimited,
            retryable: false,
            status: 'API 配额或并发受限',
            message: 'API 配额已用完，请稍后再试',
          ),
          (
            kind: LiveFailureKind.service,
            retryable: false,
            status: '需要处理',
            message: 'Gemini 服务异常，请重试',
          ),
        ];

    for (final testCase in cases) {
      final _NoopLiveSession session = _NoopLiveSession();
      final ConversationController controller = ConversationController(
        keyStore: _StoredKeyStore(),
        audioCapture: _NoopAudioCapture(),
        playback: _NoopPlayback(),
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) =>
                session,
      );
      await controller.initialize();
      await controller.startConversation();
      await tester.pumpWidget(
        MaterialApp(home: ConversationPage(controller: controller)),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('面对面模式'));
      await tester.pump();

      session.emit(
        LiveSessionFailure(
          userMessage: testCase.message,
          authenticationFailure: false,
          retryable: testCase.retryable,
          kind: testCase.kind,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text(testCase.status), findsOneWidget);
      expect(find.text(testCase.message), findsOneWidget);
      expect(
        tester.getSemantics(find.text(testCase.message)),
        matchesSemantics(label: '错误：${testCase.message}', isLiveRegion: true),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    }
  });

  testWidgets(
    'authentication failure opens key recovery and accepts replacement',
    (WidgetTester tester) async {
      final _StoredKeyStore store = _StoredKeyStore('expired-stored-key');
      final List<_NoopLiveSession> sessions = <_NoopLiveSession>[];
      final List<String> requestedKeys = <String>[];
      final ConversationController controller = ConversationController(
        keyStore: store,
        audioCapture: _NoopAudioCapture(),
        playback: _NoopPlayback(),
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) {
              requestedKeys.add(apiKey);
              final _NoopLiveSession session = _NoopLiveSession();
              sessions.add(session);
              return session;
            },
      );
      await controller.initialize();
      await controller.startConversation();
      await tester.pumpWidget(
        MaterialApp(home: ConversationPage(controller: controller)),
      );

      sessions.first.emit(
        const LiveSessionFailure(
          userMessage: 'Gemini 拒绝了这个 API Key',
          authenticationFailure: true,
          retryable: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.hasApiKey, isFalse);
      expect(store.value, isNull);
      expect(find.text('需要 API Key'), findsOneWidget);
      expect(find.text('设置 API Key'), findsOneWidget);
      expect(find.textContaining('更新 API Key'), findsOneWidget);

      await tester.tap(find.text('设置 API Key'));
      await tester.pumpAndSettle();
      expect(find.text('连接 Gemini'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'replacement-key');
      await tester.tap(find.text('在此设备上记住 Key'));
      await tester.pump();
      await tester.tap(find.text('验证并保存'));
      await tester.pumpAndSettle();

      expect(store.value, 'replacement-key');
      expect(controller.hasApiKey, isTrue);
      expect(controller.phase, ConversationPhase.idle);
      expect(find.text('准备就绪'), findsOneWidget);
      expect(find.text('开始翻译'), findsOneWidget);
      expect(requestedKeys.last, 'replacement-key');

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'routes face-to-face source to speaker and translation to listener',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final List<_NoopLiveSession> sessions = <_NoopLiveSession>[];
      final ConversationController controller = ConversationController(
        keyStore: _StoredKeyStore(),
        audioCapture: _NoopAudioCapture(),
        playback: _NoopPlayback(),
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) {
              final _NoopLiveSession session = _NoopLiveSession();
              sessions.add(session);
              return session;
            },
      );
      await controller.initialize();
      await controller.startConversation();
      await tester.pumpWidget(
        MaterialApp(home: ConversationPage(controller: controller)),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('面对面模式'));
      await tester.pumpAndSettle();

      sessions.first
        ..emit(const LiveInputTranscript('A 方中文原文', 'zh-Hans'))
        ..emit(const LiveOutputTranscript('English for person B', 'en'));
      await tester.pump();
      await tester.pump();

      final Finder sourceA = find.text('A 方中文原文');
      final Finder translationForB = find.text('English for person B');
      expect(sourceA, findsOneWidget);
      expect(translationForB, findsOneWidget);
      expect(
        tester.getCenter(translationForB).dy,
        lessThan(tester.getCenter(sourceA).dy),
      );
      expect(find.text('讲话'), findsOneWidget);
      expect(find.text('译文'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey<String>('face-half-a'))).width,
        tester.getSize(find.byKey(const ValueKey<String>('face-half-b'))).width,
      );
      expect(
        tester.getSemantics(sourceA),
        matchesSemantics(
          label: '讲话人 A，简体中文，讲话：A 方中文原文。点击切换讲话人',
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          hasTapAction: true,
          isLiveRegion: true,
        ),
      );

      sessions.first.emit(const LiveTurnComplete());
      await tester.pump();
      await tester.pump();
      expect(sourceA, findsOneWidget);
      expect(translationForB, findsOneWidget);

      sessions.first.emit(const LiveInputTranscript('A 方第二句', 'zh-Hans'));
      await tester.pump();
      await tester.pump();
      expect(find.text('English for person B'), findsNothing);
      expect(find.text('正在翻译…'), findsOneWidget);

      await tester.tap(find.text('正在翻译…'));
      await tester.pumpAndSettle();
      expect(controller.activeSpeaker, SpeakerSide.b);
      expect(sessions, hasLength(greaterThanOrEqualTo(2)));
      sessions[1]
        ..emit(const LiveInputTranscript('Person B source', 'en'))
        ..emit(const LiveOutputTranscript('给 A 方的中文译文', 'zh-Hans'));
      await tester.pump();
      await tester.pump();

      final Finder sourceB = find.text('Person B source');
      final Finder translationForA = find.text('给 A 方的中文译文');
      expect(
        tester.getCenter(sourceB).dy,
        lessThan(tester.getCenter(translationForA).dy),
      );
      expect(
        tester.getSemantics(translationForA).label,
        contains('简体中文，译文：给 A 方的中文译文'),
      );
      controller.dispose();
    },
  );

  testWidgets('keeps long face-to-face transcripts bounded on a short phone', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final List<_NoopLiveSession> sessions = <_NoopLiveSession>[];
    final ConversationController controller = ConversationController(
      keyStore: _StoredKeyStore(),
      audioCapture: _NoopAudioCapture(),
      playback: _NoopPlayback(),
      sessionFactory:
          ({required String apiKey, required String targetLanguageCode}) {
            final _NoopLiveSession session = _NoopLiveSession();
            sessions.add(session);
            return session;
          },
    );
    await controller.initialize();
    await controller.startConversation();
    await tester.pumpWidget(
      MaterialApp(home: ConversationPage(controller: controller)),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('面对面模式'));
    await tester.pump();

    final String longSource = List<String>.filled(30, '很长的旅行场景原文').join();
    final String longTranslation = List<String>.filled(
      30,
      'A long translated travel sentence ',
    ).join();
    sessions.first
      ..emit(LiveInputTranscript(longSource, 'zh-Hans'))
      ..emit(LiveOutputTranscript(longTranslation, 'en'));
    await tester.pump();
    await tester.pump();

    expect(find.text(controller.interimSource), findsOneWidget);
    expect(find.text(controller.interimTranslation), findsOneWidget);
    final Finder sourceScroll = find.descendant(
      of: find.byKey(const ValueKey<String>('face-text-scroll-a')),
      matching: find.byType(Scrollable),
    );
    expect(sourceScroll, findsOneWidget);
    final ScrollableState scrollable = tester.state<ScrollableState>(
      sourceScroll,
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    await tester.drag(sourceScroll, const Offset(0, -80));
    await tester.pump();
    expect(scrollable.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  test('permission overlays stay active while background states stop', () {
    expect(
      stopsConversationForLifecycleState(AppLifecycleState.inactive),
      isFalse,
    );
    expect(
      stopsConversationForLifecycleState(AppLifecycleState.resumed),
      isFalse,
    );
    expect(
      stopsConversationForLifecycleState(AppLifecycleState.hidden),
      isTrue,
    );
    expect(
      stopsConversationForLifecycleState(AppLifecycleState.paused),
      isTrue,
    );
    expect(
      stopsConversationForLifecycleState(AppLifecycleState.detached),
      isTrue,
    );
  });

  testWidgets('offers a recoverable and accessible denied-permission action', (
    WidgetTester tester,
  ) async {
    final _NoopPermissionGateway permissions = _NoopPermissionGateway(
      MicrophonePermissionStatus.denied,
    );
    final ConversationController controller = ConversationController(
      keyStore: _StoredKeyStore(),
      audioCapture: _NoopAudioCapture(),
      playback: _NoopPlayback(),
      permissionGateway: permissions,
      sessionFactory:
          ({required String apiKey, required String targetLanguageCode}) =>
              _NoopLiveSession(),
    );
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(home: ConversationPage(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('麦克风权限被拒绝'), findsOneWidget);
    expect(find.text('打开系统设置'), findsOneWidget);
    expect(find.text('打开麦克风设置'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('麦克风权限被拒绝')),
      matchesSemantics(label: '翻译状态：麦克风权限被拒绝', isLiveRegion: true),
    );
    expect(
      tester.getSemantics(find.text('需要麦克风权限才能进行语音翻译')),
      matchesSemantics(label: '错误：需要麦克风权限才能进行语音翻译', isLiveRegion: true),
    );
    final Finder bannerAction = find.ancestor(
      of: find.text('打开系统设置'),
      matching: find.byType(TextButton),
    );
    expect(tester.getSize(bannerAction).height, greaterThanOrEqualTo(48));

    await tester.tap(find.byTooltip('面对面模式'));
    await tester.pumpAndSettle();
    expect(find.text('麦克风权限被拒绝'), findsOneWidget);
    expect(find.text('需要麦克风权限才能进行语音翻译'), findsOneWidget);
    expect(find.text('打开系统设置'), findsOneWidget);

    await tester.tap(find.text('打开麦克风设置'));
    await tester.pump();
    expect(permissions.openSettingsCount, 1);
    controller.dispose();
  });

  testWidgets('shows translating and offline recovery states', (
    WidgetTester tester,
  ) async {
    final List<_NoopLiveSession> sessions = <_NoopLiveSession>[];
    final ConversationController controller = ConversationController(
      keyStore: _StoredKeyStore(),
      audioCapture: _NoopAudioCapture(),
      playback: _NoopPlayback(),
      sessionFactory:
          ({required String apiKey, required String targetLanguageCode}) {
            final _NoopLiveSession session = _NoopLiveSession();
            sessions.add(session);
            return session;
          },
    );
    await controller.initialize();
    await controller.startConversation();
    await tester.pumpWidget(
      MaterialApp(home: ConversationPage(controller: controller)),
    );
    await tester.pump();

    sessions.first.emit(const LiveOutputTranscript('Hello', 'en'));
    await tester.pump();
    await tester.pump();
    expect(find.text('正在翻译为 English'), findsOneWidget);
    expect(find.text('停止翻译'), findsOneWidget);

    sessions.first.emit(const LiveTurnComplete());
    await tester.pump();
    await tester.pump();
    expect(find.text('正在聆听 简体中文'), findsOneWidget);
    sessions.first.emit(
      const LiveSessionFailure(
        userMessage: '网络连接中断，恢复后将自动重连',
        authenticationFailure: false,
        retryable: true,
        kind: LiveFailureKind.offline,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('网络不可用，等待恢复'), findsOneWidget);
    expect(find.text('停止等待网络'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
      isNotNull,
    );
    controller.dispose();
  });

  testWidgets('shows a redacted Material diagnostics report', (
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

    await tester.tap(find.byTooltip('API Key 与隐私'));
    await tester.pumpAndSettle();
    expect(find.text('数据与隐私'), findsOneWidget);
    expect(
      find.textContaining('麦克风音频和转写文本会发送至 Google Gemini 处理'),
      findsOneWidget,
    );
    expect(find.textContaining('Gemini API 服务条款约束'), findsOneWidget);
    expect(find.textContaining('当前对话与译音回放仅保存在内存中'), findsOneWidget);
    expect(find.textContaining('退出应用时清除'), findsOneWidget);
    final Finder diagnosticsButton = find.text('查看运行诊断');
    await tester.ensureVisible(diagnosticsButton);
    await tester.tap(diagnosticsButton);
    await tester.pumpAndSettle();

    expect(find.text('运行诊断'), findsOneWidget);
    expect(find.textContaining('不含 Key、音频或对话内容'), findsOneWidget);
    expect(find.textContaining('Gemini Token 输入 / 输出 / 合计'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    controller.dispose();
  });

  testWidgets(
    'shows and operates Material replay control for a completed turn',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final _NoopPlayback playback = _NoopPlayback();
      final List<_NoopLiveSession> sessions = <_NoopLiveSession>[];
      final ConversationController controller = ConversationController(
        keyStore: _StoredKeyStore(),
        audioCapture: _NoopAudioCapture(),
        playback: playback,
        sessionFactory:
            ({required String apiKey, required String targetLanguageCode}) {
              final _NoopLiveSession session = _NoopLiveSession();
              sessions.add(session);
              return session;
            },
      );
      await controller.initialize();
      await controller.startConversation();
      sessions.first
        ..emit(const LiveInputTranscript('Where is the station?', 'en'))
        ..emit(const LiveOutputTranscript('车站在哪里？', 'zh-Hans'))
        ..emit(LiveAudioChunk(Uint8List(4800)))
        ..emit(const LiveTurnComplete());

      await tester.pumpWidget(
        MaterialApp(home: ConversationPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      final Finder replayButton = find.byTooltip('回放译音');
      await tester.ensureVisible(replayButton);
      expect(replayButton, findsOneWidget);
      final int enqueuesBeforeReplay = playback.enqueued.length;

      await tester.tap(replayButton);
      await tester.pump();
      expect(find.byTooltip('停止回放'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 320));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(playback.enqueued.length, enqueuesBeforeReplay + 1);
      expect(find.byTooltip('回放译音'), findsOneWidget);
      controller.dispose();
    },
  );

  testWidgets('renders with the production Material 3 light and dark themes', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final Brightness brightness in Brightness.values) {
      final ConversationController controller = _buildController();
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: _productionTheme(brightness),
          home: ConversationPage(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      final ThemeData theme = Theme.of(
        tester.element(find.byType(ConversationPage)),
      );
      final ColorScheme expectedScheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF006B68),
        brightness: brightness,
      );
      expect(theme.useMaterial3, isTrue);
      expect(theme.brightness, brightness);
      expect(theme.colorScheme.primary, expectedScheme.primary);
      expect(theme.scaffoldBackgroundColor, expectedScheme.surface);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.byType(IconButton), findsNWidgets(4));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    }
  });

  testWidgets('stays operable in RTL at 200 percent text scale', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final ConversationController controller = _buildController();
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: _productionTheme(Brightness.light),
        builder: (BuildContext context, Widget? child) {
          return MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: child!,
            ),
          );
        },
        home: ConversationPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    final BuildContext pageContext = tester.element(
      find.byType(ConversationPage),
    );
    expect(Directionality.of(pageContext), TextDirection.rtl);
    expect(MediaQuery.textScalerOf(pageContext).scale(14), 28);
    expect(find.text('开始翻译'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('面对面模式'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('标准对话模式'), findsOneWidget);
    expect(find.text('点击这里，用 简体中文 讲话'), findsOneWidget);
    expect(find.text('等待 English 译文'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
  });

  testWidgets('meets stable tap-target and semantic-label guidelines', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final ConversationController controller = _buildController();
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: _productionTheme(Brightness.light),
        home: ConversationPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
  });

  testWidgets('meets the text contrast guideline in both color schemes', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final Brightness brightness in Brightness.values) {
      final ConversationController controller = _buildController();
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: _productionTheme(brightness),
          home: ConversationPage(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(tester, meetsGuideline(textContrastGuideline));

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    }
  });
}

ConversationController _buildController() {
  return ConversationController(
    keyStore: _StoredKeyStore(),
    audioCapture: _NoopAudioCapture(),
    playback: _NoopPlayback(),
    sessionFactory:
        ({required String apiKey, required String targetLanguageCode}) =>
            _NoopLiveSession(),
  );
}

ThemeData _productionTheme(Brightness brightness) {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF006B68),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
  );
}

class _StoredKeyStore implements ApiKeyStore {
  _StoredKeyStore([this.value = 'stored-key']);

  String? value;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

class _NoopAudioCapture implements AudioCaptureGateway {
  final StreamController<Uint8List> _chunks =
      StreamController<Uint8List>.broadcast();

  @override
  Future<void> dispose() async {
    if (!_chunks.isClosed) {
      await _chunks.close();
    }
  }

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<Uint8List>> start() async => _chunks.stream;

  @override
  Future<void> stop() async {}
}

class _NoopPermissionGateway implements MicrophonePermissionGateway {
  _NoopPermissionGateway(this.status);

  MicrophonePermissionStatus? status;
  int openSettingsCount = 0;

  @override
  Stream<MicrophonePermissionStatus> get changes =>
      const Stream<MicrophonePermissionStatus>.empty();

  @override
  Future<MicrophonePermissionStatus?> currentStatus() async => status;

  @override
  Future<void> openAppSettings() async {
    openSettingsCount += 1;
  }

  @override
  Future<void> recordRequestResult({required bool granted}) async {}
}

class _NoopPlayback implements PcmPlaybackGateway {
  final List<List<int>> enqueued = <List<int>>[];

  @override
  Stream<PcmPlaybackEvent> get events => const Stream<PcmPlaybackEvent>.empty();

  @override
  Future<void> configure({required int clientGeneration}) async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> enqueue(Uint8List pcm) async => enqueued.add(pcm.toList());

  @override
  Future<void> flush() async {}

  @override
  Future<PcmPlaybackMetrics> metrics() async =>
      const PcmPlaybackMetrics.empty();
}

class _NoopLiveSession implements LiveTranslationSession {
  final StreamController<LiveEvent> _events =
      StreamController<LiveEvent>.broadcast();

  void emit(LiveEvent event) => _events.add(event);

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

  @override
  void endAudioStream() {}
}

class _GatedLiveSession extends _NoopLiveSession {
  final Completer<void> _connection = Completer<void>();
  bool _ready = false;

  void releaseConnection() {
    if (!_connection.isCompleted) {
      _ready = true;
      _connection.complete();
    }
  }

  @override
  Future<void> connect() => _connection.future;

  @override
  bool get isReady => _ready;
}
