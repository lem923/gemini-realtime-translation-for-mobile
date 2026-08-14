import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../audio/headset_capture_gateway.dart';
import '../conversation/conversation_controller.dart';
import '../conversation/conversation_diagnostics.dart';
import '../conversation/conversation_models.dart';
import '../shared/crash_log.dart';
import '../shared/translation_language.dart';

@visibleForTesting
bool stopsConversationForLifecycleState(AppLifecycleState state) =>
    state == AppLifecycleState.hidden ||
    state == AppLifecycleState.paused ||
    state == AppLifecycleState.detached;

class ConversationPage extends StatefulWidget {
  const ConversationPage({required this.controller, super.key});

  final ConversationController controller;

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage>
    with WidgetsBindingObserver {
  bool _faceToFace = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Permission prompts and other temporary system overlays emit `inactive`.
    // Stopping there cancels the very microphone request that starts a session.
    if (stopsConversationForLifecycleState(state)) {
      unawaited(widget.controller.stopConversation());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(widget.controller.refreshMicrophonePermission());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (BuildContext context, Widget? child) {
        final ConversationController controller = widget.controller;
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: const _BrandTitle(),
            actions: <Widget>[
              IconButton(
                tooltip: _faceToFace ? '标准对话模式' : '面对面模式',
                onPressed: () => setState(() => _faceToFace = !_faceToFace),
                icon: Icon(
                  _faceToFace
                      ? Icons.view_agenda_outlined
                      : Icons.screen_rotation_alt_outlined,
                ),
              ),
              IconButton(
                tooltip: controller.audioMuted ? '开启译文语音' : '静音译文语音',
                onPressed: controller.toggleAudioMuted,
                icon: Icon(
                  controller.audioMuted
                      ? Icons.volume_off_outlined
                      : Icons.volume_up_outlined,
                ),
              ),
              IconButton(
                tooltip: 'API Key 与隐私',
                onPressed: () => _showApiKeySheet(context, controller),
                icon: const Icon(Icons.tune_rounded),
              ),
              const SizedBox(width: 6),
            ],
          ),
          body: !controller.initialized
              ? const Center(child: CircularProgressIndicator())
              : _faceToFace
              ? _FaceToFaceView(controller: controller)
              : _ConversationBody(controller: controller),
          bottomNavigationBar: controller.initialized
              ? _ControlDock(
                  controller: controller,
                  onNeedsKey: () => _showApiKeySheet(context, controller),
                )
              : null,
        );
      },
    );
  }
}

class _BrandTitle extends StatelessWidget {
  const _BrandTitle();

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(Icons.translate_rounded, color: colors.primary),
        ),
        const SizedBox(width: 11),
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('即时翻译', style: TextStyle(fontWeight: FontWeight.w700)),
            Text(
              'Gemini Live',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ],
    );
  }
}

class _ConversationBody extends StatelessWidget {
  const _ConversationBody({required this.controller});

  final ConversationController controller;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          sliver: SliverList.list(
            children: <Widget>[
              _StatusStrip(controller: controller),
              const SizedBox(height: 12),
              _ModeSelector(controller: controller),
              if (!controller.hasApiKey) ...<Widget>[
                const SizedBox(height: 12),
                const _SetupBanner(),
              ],
              if (controller.errorMessage != null) ...<Widget>[
                const SizedBox(height: 12),
                _ErrorBanner(
                  message: controller.errorMessage!,
                  actionLabel:
                      controller.phase == ConversationPhase.permissionDenied
                      ? '打开系统设置'
                      : null,
                  onAction:
                      controller.phase == ConversationPhase.permissionDenied
                      ? () => unawaited(controller.openMicrophoneSettings())
                      : null,
                ),
              ],
              const SizedBox(height: 16),
              _LanguagePair(controller: controller),
              const SizedBox(height: 16),
              _LiveTranscriptCard(controller: controller),
              const SizedBox(height: 22),
              _HistoryHeader(controller: controller),
              const SizedBox(height: 10),
              if (controller.turns.isEmpty)
                const _EmptyConversation()
              else
                for (final ConversationTurn turn in controller.turns.reversed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _TurnCard(turn: turn, controller: controller),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ModeSelector extends StatelessWidget {
  const _ModeSelector({required this.controller, this.showHint = true});

  final ConversationController controller;
  final bool showHint;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool lectureMode = controller.mode == ConversationMode.lecture;
    final String hint = lectureMode
        ? controller.lectureChannel == LectureInputChannel.headsetMic
              ? controller.headsetState != HeadsetCaptureState.available
                    ? '讲座模式：选择了耳机麦克风，但未检测到带麦克风的耳机'
                    : '讲座模式：耳机麦收音，译文实时播到耳机（不使用手机扬声器）'
              : '讲座模式：手机麦收音，译文实时播到耳机（不使用手机扬声器）'
        : controller.mode == ConversationMode.simultaneous
        ? '同声传译：麦克风在译文播放时保持开启，适合耳机使用'
        : '逐句翻译：说完一句，听完译文，再讲下一句';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Center(
          child: SegmentedButton<ConversationMode>(
            segments: const <ButtonSegment<ConversationMode>>[
              ButtonSegment<ConversationMode>(
                value: ConversationMode.sentenceBySentence,
                label: Text('逐句翻译'),
                tooltip: '说完一句，听完译文，再讲下一句',
              ),
              ButtonSegment<ConversationMode>(
                value: ConversationMode.simultaneous,
                label: Text('同声传译'),
                tooltip: '边说边听，译文随讲随播，建议佩戴耳机',
              ),
              ButtonSegment<ConversationMode>(
                value: ConversationMode.lecture,
                label: Text('讲座模式'),
                tooltip: '选择来源与译文语言和麦克风通道，译文实时播到耳机',
              ),
            ],
            selected: <ConversationMode>{controller.mode},
            onSelectionChanged: (Set<ConversationMode> selection) {
              controller.setMode(selection.first);
            },
            showSelectedIcon: false,
            style: ButtonStyle(
              tapTargetSize: MaterialTapTargetSize.padded,
              minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 48)),
              textStyle: WidgetStatePropertyAll<TextStyle>(
                TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: colors.onSurface,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 7),
        if (showHint)
          Text(
            hint,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: colors.onSurfaceVariant,
              height: 1.3,
            ),
          ),
      ],
    );
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.controller});

  final ConversationController controller;

  @override
  Widget build(BuildContext context) {
    final (
      String label,
      IconData icon,
      Color color,
    ) = switch (controller.phase) {
      ConversationPhase.needsKey => (
        '需要 API Key',
        Icons.key_outlined,
        Theme.of(context).colorScheme.tertiary,
      ),
      ConversationPhase.idle => (
        '准备就绪',
        Icons.check_circle_outline,
        Theme.of(context).colorScheme.primary,
      ),
      ConversationPhase.connecting => (
        '正在连接',
        Icons.cloud_sync_outlined,
        Theme.of(context).colorScheme.secondary,
      ),
      ConversationPhase.listening => (
        '正在聆听 ${controller.activeSourceLanguage.name}',
        Icons.mic_rounded,
        Theme.of(context).colorScheme.primary,
      ),
      ConversationPhase.translating => (
        '正在翻译为 ${controller.activeTargetLanguage.name}',
        Icons.graphic_eq_rounded,
        Theme.of(context).colorScheme.primary,
      ),
      ConversationPhase.reconnecting => (
        '连接恢复中',
        Icons.sync_rounded,
        Theme.of(context).colorScheme.secondary,
      ),
      ConversationPhase.offline => (
        controller.isBusy ? '网络不可用，等待恢复' : '当前处于离线状态',
        Icons.cloud_off_outlined,
        Theme.of(context).colorScheme.error,
      ),
      ConversationPhase.rateLimited => (
        'API 配额或并发受限',
        Icons.hourglass_top_rounded,
        Theme.of(context).colorScheme.error,
      ),
      ConversationPhase.permissionDenied => (
        '麦克风权限被拒绝',
        Icons.mic_off_outlined,
        Theme.of(context).colorScheme.error,
      ),
      ConversationPhase.failed => (
        '需要处理',
        Icons.error_outline,
        Theme.of(context).colorScheme.error,
      ),
    };
    return Semantics(
      liveRegion: true,
      excludeSemantics: true,
      label: '翻译状态：$label',
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.11),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SetupBanner extends StatelessWidget {
  const _SetupBanner();

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.shield_outlined, color: colors.onSecondaryContainer),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              '使用你自己的 Gemini API Key。默认只保存在内存中，不会上传到项目服务器。',
              style: TextStyle(fontSize: 13, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, this.actionLabel, this.onAction});
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.errorContainer,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Semantics(
              liveRegion: true,
              excludeSemantics: true,
              label: '错误：$message',
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.info_outline_rounded,
                    color: colors.onErrorContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      message,
                      style: TextStyle(color: colors.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
            if (actionLabel != null && onAction != null) ...<Widget>[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onAction,
                  icon: const Icon(Icons.settings_outlined),
                  label: Text(actionLabel!),
                  style: TextButton.styleFrom(
                    foregroundColor: colors.onErrorContainer,
                    minimumSize: const Size(48, 48),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LanguagePair extends StatelessWidget {
  const _LanguagePair({required this.controller});
  final ConversationController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.isHeadsetMode) {
      return _LectureConfig(controller: controller);
    }
    return Row(
      children: <Widget>[
        Expanded(
          child: _SpeakerCard(
            side: SpeakerSide.a,
            language: controller.languageA,
            selected: controller.activeSpeaker == SpeakerSide.a,
            onSelect: () => unawaited(controller.selectSpeaker(SpeakerSide.a)),
            onLanguage: () => _pickLanguage(context, controller, SpeakerSide.a),
            badge: controller.isHeadsetMode ? '机主' : 'A',
            semanticName: controller.isHeadsetMode ? '机主' : '讲话人 A',
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: IconButton.filledTonal(
            tooltip: '交换语言',
            onPressed: () => unawaited(controller.swapLanguages()),
            icon: const Icon(Icons.swap_horiz_rounded),
          ),
        ),
        Expanded(
          child: _SpeakerCard(
            side: SpeakerSide.b,
            language: controller.languageB,
            selected: controller.activeSpeaker == SpeakerSide.b,
            onSelect: () => unawaited(controller.selectSpeaker(SpeakerSide.b)),
            onLanguage: () => _pickLanguage(context, controller, SpeakerSide.b),
            badge: controller.isHeadsetMode ? '对方' : 'B',
            semanticName: controller.isHeadsetMode ? '对方' : '讲话人 B',
          ),
        ),
      ],
    );
  }
}

class _LectureConfig extends StatelessWidget {
  const _LectureConfig({required this.controller});

  final ConversationController controller;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color accent = colors.primary;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: colors.outlineVariant, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '讲座模式',
            style: TextStyle(fontWeight: FontWeight.w800, color: accent),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: _LectureLanguageChip(
                  label: '来源语言',
                  language: controller.languageA,
                  onTap: () =>
                      _pickLanguage(context, controller, SpeakerSide.a),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  color: colors.onSurfaceVariant,
                ),
              ),
              Expanded(
                child: _LectureLanguageChip(
                  label: '译文语言',
                  language: controller.languageB,
                  onTap: () =>
                      _pickLanguage(context, controller, SpeakerSide.b),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedButton<LectureInputChannel>(
            segments: const <ButtonSegment<LectureInputChannel>>[
              ButtonSegment<LectureInputChannel>(
                value: LectureInputChannel.phoneMic,
                label: Text('手机麦克风'),
              ),
              ButtonSegment<LectureInputChannel>(
                value: LectureInputChannel.headsetMic,
                label: Text('耳机麦克风'),
              ),
            ],
            selected: <LectureInputChannel>{controller.lectureChannel},
            onSelectionChanged: (Set<LectureInputChannel> selection) {
              controller.setLectureChannel(selection.first);
            },
            showSelectedIcon: false,
            style: ButtonStyle(
              tapTargetSize: MaterialTapTargetSize.padded,
              minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 48)),
              textStyle: WidgetStatePropertyAll<TextStyle>(
                TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: colors.onSurface,
                ),
              ),
            ),
          ),
          const SizedBox(height: 9),
          Text(
            '选定的麦克风收到${controller.languageA.name}语音时，译文将实时播到你的耳机（不使用手机扬声器）。',
            style: TextStyle(
              fontSize: 12,
              color: colors.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _LectureLanguageChip extends StatelessWidget {
  const _LectureLanguageChip({
    required this.label,
    required this.language,
    required this.onTap,
  });

  final String label;
  final TranslationLanguage language;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Semantics(
          button: true,
          onTap: onTap,
          label: '$label ${language.name}',
          excludeSemantics: true,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHigh.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: colors.outlineVariant, width: 1),
                ),
                child: Row(
                  children: <Widget>[
                    Text(language.flag, style: const TextStyle(fontSize: 18)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        language.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const Icon(Icons.expand_more_rounded, size: 18),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SpeakerCard extends StatelessWidget {
  const _SpeakerCard({
    required this.side,
    required this.language,
    required this.selected,
    required this.onSelect,
    required this.onLanguage,
    required this.badge,
    required this.semanticName,
  });

  final SpeakerSide side;
  final TranslationLanguage language;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onLanguage;
  final String badge;
  final String semanticName;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color accent = side == SpeakerSide.a
        ? colors.primary
        : colors.tertiary;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: selected
            ? accent.withValues(alpha: 0.12)
            : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: selected ? accent : colors.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            selected: selected,
            button: true,
            onTap: onSelect,
            label: '$semanticName ${language.name}',
            excludeSemantics: true,
            child: InkWell(
              onTap: onSelect,
              borderRadius: BorderRadius.circular(22),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(
                          selected
                              ? Icons.mic_rounded
                              : Icons.person_outline_rounded,
                          color: accent,
                          size: 20,
                        ),
                        const Spacer(),
                        Text(
                          badge,
                          style: TextStyle(
                            color: accent,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(language.flag, style: const TextStyle(fontSize: 24)),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Tooltip(
              message: '更换语言',
              child: Semantics(
                button: true,
                onTap: onLanguage,
                label: '更换语言 ${language.name}',
                excludeSemantics: true,
                child: InkWell(
                  onTap: onLanguage,
                  borderRadius: BorderRadius.circular(10),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHigh.withValues(
                          alpha: 0.55,
                        ),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: colors.outlineVariant,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              language.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.expand_more_rounded, size: 18),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveTranscriptCard extends StatelessWidget {
  const _LiveTranscriptCard({required this.controller});
  final ConversationController controller;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool hasText =
        controller.interimSource.isNotEmpty ||
        controller.interimTranslation.isNotEmpty;
    return Container(
      constraints: const BoxConstraints(minHeight: 154),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: hasText
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _TranscriptLabel(
                  label: controller.activeSourceLanguage.name,
                  listening: controller.isListening,
                ),
                const SizedBox(height: 8),
                Text(
                  controller.interimSource.isEmpty
                      ? '…'
                      : controller.interimSource,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 13),
                  child: Divider(height: 1),
                ),
                Text(
                  controller.activeTargetLanguage.name,
                  style: TextStyle(
                    color: colors.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  controller.interimTranslation.isEmpty
                      ? '正在生成译文…'
                      : controller.interimTranslation,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(
                  controller.isListening
                      ? Icons.graphic_eq_rounded
                      : Icons.spatial_audio_off_outlined,
                  size: 38,
                  color: controller.isListening
                      ? colors.primary
                      : colors.onSurfaceVariant,
                ),
                const SizedBox(height: 11),
                Text(
                  controller.isListening
                      ? '请用 ${controller.activeSourceLanguage.name} 讲话'
                      : '选择讲话人，然后开始翻译',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 5),
                Text(
                  '译文将以文字和声音同时输出',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
    );
  }
}

class _TranscriptLabel extends StatelessWidget {
  const _TranscriptLabel({required this.label, required this.listening});
  final String label;
  final bool listening;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (listening) ...<Widget>[
          const SizedBox(width: 7),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ],
    );
  }
}

class _HistoryHeader extends StatelessWidget {
  const _HistoryHeader({required this.controller});
  final ConversationController controller;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Text(
          '对话记录',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const Spacer(),
        if (controller.turns.isNotEmpty)
          TextButton.icon(
            onPressed: controller.clearHistory,
            icon: const Icon(Icons.delete_sweep_outlined, size: 18),
            label: const Text('清空'),
          ),
      ],
    );
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation();

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: const Column(
        children: <Widget>[
          Text('旅行场景提示', style: TextStyle(fontWeight: FontWeight.w700)),
          SizedBox(height: 11),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: <Widget>[
              Chip(label: Text('🏨 酒店')),
              Chip(label: Text('🍜 餐厅')),
              Chip(label: Text('🚕 出行')),
              Chip(label: Text('🛍️ 购物')),
              Chip(label: Text('🆘 求助')),
            ],
          ),
        ],
      ),
    );
  }
}

class _TurnCard extends StatelessWidget {
  const _TurnCard({required this.turn, required this.controller});
  final ConversationTurn turn;
  final ConversationController controller;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool isA = turn.speaker == SpeakerSide.a;
    final Color accent = isA ? colors.primary : colors.tertiary;
    final bool hasReplay = controller.hasReplayAudio(turn.id);
    final bool replaying = controller.replayingTurnId == turn.id;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              CircleAvatar(
                radius: 15,
                backgroundColor: accent.withValues(alpha: 0.14),
                child: Text(
                  isA ? 'A' : 'B',
                  style: TextStyle(
                    color: accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  '${turn.sourceLanguage.name} → ${turn.targetLanguage.name}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (hasReplay) ...<Widget>[
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: replaying ? '停止回放' : '回放译音',
                  onPressed: controller.audioMuted
                      ? null
                      : () => unawaited(controller.replayTurn(turn.id)),
                  icon: Icon(
                    replaying ? Icons.stop_rounded : Icons.volume_up_rounded,
                    size: 20,
                  ),
                ),
              ],
            ],
          ),
          if (turn.sourceText.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(turn.sourceText, style: Theme.of(context).textTheme.bodyLarge),
          ],
          if (turn.translatedText.isNotEmpty) ...<Widget>[
            const SizedBox(height: 9),
            Text(
              turn.translatedText,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ControlDock extends StatelessWidget {
  const _ControlDock({required this.controller, required this.onNeedsKey});
  final ConversationController controller;
  final VoidCallback onNeedsKey;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool busy = controller.isBusy;
    final bool pttMode = controller.mode == ConversationMode.sentenceBySentence;
    final String label = !controller.hasApiKey
        ? '设置 API Key'
        : controller.phase == ConversationPhase.permissionDenied
        ? '打开麦克风设置'
        : controller.replayingTurnId != null
        ? '正在回放译音…'
        : pttMode
        ? '停止翻译'
        : controller.isListening
        ? '停止翻译'
        : controller.canStopConversation &&
              controller.phase == ConversationPhase.connecting
        ? '取消连接'
        : controller.canStopConversation
        ? '停止等待网络'
        : controller.phase == ConversationPhase.offline
        ? '重新连接'
        : controller.phase == ConversationPhase.rateLimited
        ? '稍后重试'
        : busy
        ? '正在连接…'
        : '开始翻译';
    final IconData icon = !controller.hasApiKey
        ? Icons.key_rounded
        : controller.phase == ConversationPhase.permissionDenied
        ? Icons.settings_outlined
        : controller.replayingTurnId != null
        ? Icons.volume_up_rounded
        : controller.canStopConversation
        ? Icons.stop_rounded
        : controller.phase == ConversationPhase.offline
        ? Icons.cloud_off_outlined
        : controller.phase == ConversationPhase.rateLimited
        ? Icons.hourglass_top_rounded
        : Icons.mic_rounded;
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          borderRadius: BorderRadius.circular(26),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: colors.shadow.withValues(alpha: 0.08),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: pttMode
            ? _PttDock(controller: controller, onNeedsKey: onNeedsKey)
            : SizedBox(
                height: 58,
                child: FilledButton.icon(
                  onPressed: busy && !controller.canStopConversation
                      ? null
                      : () {
                          if (!controller.hasApiKey) {
                            onNeedsKey();
                          } else if (controller.phase ==
                              ConversationPhase.permissionDenied) {
                            unawaited(controller.openMicrophoneSettings());
                          } else if (controller.canStopConversation) {
                            unawaited(controller.stopConversation());
                          } else {
                            unawaited(controller.startConversation());
                          }
                        },
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(icon),
                  label: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _PttDock extends StatelessWidget {
  const _PttDock({required this.controller, required this.onNeedsKey});

  final ConversationController controller;
  final VoidCallback onNeedsKey;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    if (!controller.hasApiKey) {
      return SizedBox(
        height: 58,
        child: FilledButton.icon(
          onPressed: onNeedsKey,
          icon: const Icon(Icons.key_rounded),
          label: const Text(
            '设置 API Key',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
      );
    }
    if (controller.phase == ConversationPhase.permissionDenied) {
      return SizedBox(
        height: 58,
        child: FilledButton.icon(
          onPressed: () => unawaited(controller.openMicrophoneSettings()),
          icon: const Icon(Icons.settings_outlined),
          label: const Text(
            '打开麦克风设置',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
      );
    }
    if (!controller.isListening && !controller.isBusy) {
      return SizedBox(
        height: 58,
        child: FilledButton.icon(
          onPressed: () => unawaited(controller.startConversation()),
          icon: const Icon(Icons.mic_rounded),
          label: const Text(
            '开始翻译',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Semantics(
                button: true,
                label: controller.pttActive ? '松开结束说话' : '按住说话',
                excludeSemantics: true,
                child: GestureDetector(
                  onTapDown: (_) => controller.startUtterance(),
                  onTapUp: (_) => controller.endUtterance(),
                  onTapCancel: controller.endUtterance,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    height: 58,
                    decoration: BoxDecoration(
                      color: controller.pttActive
                          ? colors.primary
                          : colors.primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(color: colors.primary, width: 1.5),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      controller.pttActive ? '松开结束' : '按住说话',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: controller.pttActive
                            ? colors.onPrimary
                            : colors.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filledTonal(
              tooltip: '停止翻译',
              onPressed: controller.canStopConversation
                  ? () => unawaited(controller.stopConversation())
                  : null,
              icon: const Icon(Icons.stop_rounded),
            ),
          ],
        ),
      ],
    );
  }
}

class _FaceToFaceView extends StatelessWidget {
  const _FaceToFaceView({required this.controller});
  final ConversationController controller;

  @override
  Widget build(BuildContext context) {
    final ConversationTurn? latestTurn = controller.latestActiveTurn;
    final bool hasInterim = controller.hasInterimTranscript;
    final String visibleSource = hasInterim
        ? controller.interimSource
        : latestTurn?.sourceText ?? '';
    final String visibleTranslation = hasInterim
        ? controller.interimTranslation
        : latestTurn?.translatedText ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Column(
        children: <Widget>[
          _FaceStatusPanel(controller: controller),
          const SizedBox(height: 8),
          Expanded(
            child: SizedBox(
              width: double.infinity,
              child: Transform.rotate(
                angle: math.pi,
                child: _FaceHalf(
                  controller: controller,
                  side: SpeakerSide.b,
                  visibleSource: visibleSource,
                  visibleTranslation: visibleTranslation,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: IconButton.filledTonal(
              tooltip: '交换语言',
              onPressed: () => unawaited(controller.swapLanguages()),
              icon: const Icon(Icons.swap_vert_rounded),
            ),
          ),
          Expanded(
            child: SizedBox(
              width: double.infinity,
              child: _FaceHalf(
                controller: controller,
                side: SpeakerSide.a,
                visibleSource: visibleSource,
                visibleTranslation: visibleTranslation,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FaceStatusPanel extends StatelessWidget {
  const _FaceStatusPanel({required this.controller});

  final ConversationController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _StatusStrip(controller: controller),
        const SizedBox(height: 8),
        _ModeSelector(controller: controller, showHint: false),
        if (controller.errorMessage != null) ...<Widget>[
          const SizedBox(height: 8),
          _ErrorBanner(
            message: controller.errorMessage!,
            actionLabel: controller.phase == ConversationPhase.permissionDenied
                ? '打开系统设置'
                : null,
            onAction: controller.phase == ConversationPhase.permissionDenied
                ? () => unawaited(controller.openMicrophoneSettings())
                : null,
          ),
        ],
      ],
    );
  }
}

class _FaceHalf extends StatelessWidget {
  const _FaceHalf({
    required this.controller,
    required this.side,
    required this.visibleSource,
    required this.visibleTranslation,
  });
  final ConversationController controller;
  final SpeakerSide side;
  final String visibleSource;
  final String visibleTranslation;

  @override
  Widget build(BuildContext context) {
    final bool selected = controller.activeSpeaker == side;
    final TranslationLanguage language = side == SpeakerSide.a
        ? controller.languageA
        : controller.languageB;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color accent = side == SpeakerSide.a
        ? colors.primary
        : colors.tertiary;
    final bool hasConversationText =
        visibleSource.isNotEmpty || visibleTranslation.isNotEmpty;
    final String role = selected ? '讲话' : '译文';
    final String text = selected
        ? visibleSource.isNotEmpty
              ? visibleSource
              : hasConversationText
              ? '正在识别…'
              : '点击这里，用 ${language.name} 讲话'
        : visibleTranslation.isNotEmpty
        ? visibleTranslation
        : hasConversationText
        ? '正在翻译…'
        : '等待 ${language.name} 译文';
    void selectSpeaker() => unawaited(controller.selectSpeaker(side));
    return Semantics(
      button: true,
      selected: selected,
      liveRegion: hasConversationText,
      excludeSemantics: true,
      onTap: selectSpeaker,
      label:
          '${side == SpeakerSide.a ? '讲话人 A' : '讲话人 B'}，${language.name}，$role：$text。点击切换讲话人',
      child: Material(
        key: ValueKey<String>('face-half-${side.name}'),
        color: selected
            ? accent.withValues(alpha: 0.13)
            : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool compact = constraints.maxHeight < 240;
            final double gap = compact ? 4 : 12;
            final Widget roleBadge = Container(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 8 : 11,
                vertical: compact ? 3 : 5,
              ),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    selected ? Icons.mic_rounded : Icons.translate_rounded,
                    color: accent,
                    size: compact ? 17 : 20,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    role,
                    style: TextStyle(
                      color: accent,
                      fontSize: compact ? 11 : 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            );
            return InkWell(
              onTap: selectSpeaker,
              child: Padding(
                padding: EdgeInsets.all(compact ? 8 : 22),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    if (compact)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          Text(
                            language.flag,
                            style: const TextStyle(fontSize: 22),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              language.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: accent,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          roleBadge,
                        ],
                      )
                    else ...<Widget>[
                      Text(language.flag, style: const TextStyle(fontSize: 36)),
                      const SizedBox(height: 8),
                      Text(
                        language.name,
                        style: TextStyle(
                          color: accent,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: gap),
                      roleBadge,
                    ],
                    SizedBox(height: gap),
                    Expanded(
                      child: Center(
                        child: SingleChildScrollView(
                          key: ValueKey<String>(
                            'face-text-scroll-${side.name}',
                          ),
                          primary: false,
                          child: Text(
                            text,
                            textAlign: TextAlign.center,
                            style:
                                (compact
                                        ? Theme.of(
                                            context,
                                          ).textTheme.titleMedium
                                        : Theme.of(
                                            context,
                                          ).textTheme.titleLarge)
                                    ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

Future<void> _pickLanguage(
  BuildContext context,
  ConversationController controller,
  SpeakerSide side,
) async {
  final TranslationLanguage? picked =
      await showModalBottomSheet<TranslationLanguage>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (BuildContext context) => const _LanguagePickerSheet(),
      );
  if (picked != null) {
    await controller.setLanguage(side, picked);
  }
}

class _LanguagePickerSheet extends StatefulWidget {
  const _LanguagePickerSheet();

  @override
  State<_LanguagePickerSheet> createState() => _LanguagePickerSheetState();
}

class _LanguagePickerSheetState extends State<_LanguagePickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final String normalized = _query.trim().toLowerCase();
    final List<TranslationLanguage> languages = supportedLanguages
        .where(
          (TranslationLanguage language) =>
              normalized.isEmpty ||
              language.name.toLowerCase().contains(normalized) ||
              language.code.toLowerCase().contains(normalized),
        )
        .toList(growable: false);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.78,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
            child: TextField(
              autofocus: true,
              onChanged: (String value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: '搜索语言或代码',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: languages.length,
              itemBuilder: (BuildContext context, int index) {
                final TranslationLanguage language = languages[index];
                return ListTile(
                  leading: Text(
                    language.flag,
                    style: const TextStyle(fontSize: 25),
                  ),
                  title: Text(language.name),
                  subtitle: Text(language.code),
                  onTap: () => Navigator.pop(context, language),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _showApiKeySheet(
  BuildContext context,
  ConversationController controller,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (BuildContext context) => _ApiKeySheet(controller: controller),
  );
}

class _ApiKeySheet extends StatefulWidget {
  const _ApiKeySheet({required this.controller});
  final ConversationController controller;

  @override
  State<_ApiKeySheet> createState() => _ApiKeySheetState();
}

class _ApiKeySheetState extends State<_ApiKeySheet> {
  final TextEditingController _keyController = TextEditingController();
  bool _obscure = true;
  bool _remember = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _remember = widget.controller.rememberKey;
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '连接 Gemini',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 7),
            Text(
              widget.controller.hasApiKey
                  ? '已配置 API Key。留空可验证现有 Key，输入新值可替换。'
                  : '请输入你自己的 Google AI Studio API Key。没有 Key 时翻译功能不可用。',
              style: TextStyle(color: colors.onSurfaceVariant, height: 1.45),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _keyController,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Gemini API Key',
                hintText: widget.controller.hasApiKey
                    ? '••••••••••••••••'
                    : 'AIza…',
                prefixIcon: const Icon(Icons.key_rounded),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('在此设备上记住 Key'),
              subtitle: const Text('关闭时仅保存在当前应用内存中'),
              value: _remember,
              onChanged: (bool value) => setState(() => _remember = value),
            ),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.primaryContainer.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.lock_outline_rounded, color: colors.primary),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '数据与隐私',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        SizedBox(height: 5),
                        Text(
                          'API Key 只用于从本机直连 Google Gemini。麦克风音频和转写文本会发送至 Google Gemini 处理，Google 侧的数据处理受 Gemini API 服务条款约束。',
                          style: TextStyle(fontSize: 12, height: 1.45),
                        ),
                        SizedBox(height: 5),
                        Text(
                          '本地当前对话与译音回放仅保存在内存中，退出应用时清除；应用没有账号、项目后端或云端对话存储。',
                          style: TextStyle(fontSize: 12, height: 1.45),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (widget.controller.errorMessage != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                widget.controller.errorMessage!,
                style: TextStyle(
                  color: colors.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                onPressed: _saving
                    ? null
                    : () => _showDiagnosticsDialog(context, widget.controller),
                icon: const Icon(Icons.monitor_heart_outlined),
                label: const Text('查看运行诊断'),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.verified_outlined),
                label: Text(_saving ? '正在验证…' : '验证并保存'),
              ),
            ),
            if (widget.controller.hasApiKey)
              Center(
                child: TextButton(
                  onPressed: _saving
                      ? null
                      : () async {
                          await widget.controller.removeApiKey();
                          if (context.mounted) {
                            Navigator.pop(context);
                          }
                        },
                  child: const Text('移除本机 API Key'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final bool success = await widget.controller.validateAndSaveApiKey(
      candidate: _keyController.text,
      remember: _remember,
    );
    if (!mounted) {
      return;
    }
    setState(() => _saving = false);
    if (success) {
      Navigator.pop(context);
    }
  }
}

Future<void> _showDiagnosticsDialog(
  BuildContext context,
  ConversationController controller,
) async {
  final ConversationDiagnostics diagnostics = await controller
      .collectDiagnostics();
  final StringBuffer report = StringBuffer(diagnostics.toRedactedText());
  final String nativeLog = await CrashLog.instance.readNativeLog();
  final List<String> dartEntries = CrashLog.instance.entries;
  if (dartEntries.isNotEmpty || nativeLog.isNotEmpty) {
    report.writeln();
    report.writeln('本机崩溃日志（最近，仅供开发者诊断）:');
    final int dartStart = dartEntries.length > 4 ? dartEntries.length - 4 : 0;
    for (final String entry in dartEntries.sublist(dartStart)) {
      report.writeln(entry.split('\n').take(4).join(' / '));
    }
    if (nativeLog.isNotEmpty) {
      final List<String> lines = nativeLog.trim().split('\n');
      final int nativeStart = lines.length > 8 ? lines.length - 8 : 0;
      report.writeln(lines.sublist(nativeStart).join('\n'));
    }
  }
  if (!context.mounted) {
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      icon: const Icon(Icons.monitor_heart_outlined),
      title: const Text('运行诊断'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 520),
        child: SingleChildScrollView(
          child: SelectableText(
            report.toString(),
            style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              height: 1.55,
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: report.toString()));
            if (dialogContext.mounted) {
              Navigator.pop(dialogContext);
            }
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('已复制脱敏诊断信息')));
            }
          },
          icon: const Icon(Icons.copy_rounded),
          label: const Text('复制'),
        ),
      ],
    ),
  );
}
