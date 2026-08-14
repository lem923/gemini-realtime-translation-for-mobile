import 'package:flutter/foundation.dart';

import '../audio/pcm_playback_gateway.dart';
import 'conversation_models.dart';

@immutable
class ConversationDiagnostics {
  const ConversationDiagnostics({
    required this.phase,
    required this.mode,
    required this.sessionDurationMilliseconds,
    required this.microphoneChunksSent,
    required this.microphoneChunksSuppressed,
    required this.microphoneChunksHeld,
    required this.utterancesDetected,
    required this.bargeIns,
    required this.sentenceTurnsCompleted,
    required this.autoDirectionSwitches,
    required this.headsetState,
    required this.outputAudioChunks,
    required this.outputAudioBytes,
    required this.completedTurns,
    required this.directionSwitches,
    required this.reconnectEvents,
    required this.sessionFailures,
    required this.playbackFailures,
    required this.lastPlaybackFailureReason,
    required this.lastPlaybackFailurePlatformCode,
    required this.audioInterruptions,
    required this.geminiPromptTokens,
    required this.geminiResponseTokens,
    required this.geminiTotalTokens,
    required this.geminiUsageAvailable,
    required this.listeningReadyMilliseconds,
    required this.firstMicrophoneSentMilliseconds,
    required this.firstSourceTextMilliseconds,
    required this.firstTranslatedTextMilliseconds,
    required this.firstTranslatedAudioMilliseconds,
    required this.maximumScheduledPlaybackMilliseconds,
    required this.playbackMetrics,
    required this.playbackMetricsAvailable,
  });

  final ConversationPhase phase;
  final ConversationMode mode;
  final int sessionDurationMilliseconds;
  final int microphoneChunksSent;
  final int microphoneChunksSuppressed;
  final int microphoneChunksHeld;
  final int utterancesDetected;
  final int bargeIns;
  final int sentenceTurnsCompleted;
  final int autoDirectionSwitches;
  final String headsetState;
  final int outputAudioChunks;
  final int outputAudioBytes;
  final int completedTurns;
  final int directionSwitches;
  final int reconnectEvents;
  final int sessionFailures;
  final int playbackFailures;
  final String? lastPlaybackFailureReason;
  final int? lastPlaybackFailurePlatformCode;
  final int audioInterruptions;
  final int geminiPromptTokens;
  final int geminiResponseTokens;
  final int geminiTotalTokens;
  final bool geminiUsageAvailable;
  final int? listeningReadyMilliseconds;
  final int? firstMicrophoneSentMilliseconds;
  final int? firstSourceTextMilliseconds;
  final int? firstTranslatedTextMilliseconds;
  final int? firstTranslatedAudioMilliseconds;
  final int maximumScheduledPlaybackMilliseconds;
  final PcmPlaybackMetrics playbackMetrics;
  final bool playbackMetricsAvailable;

  String toRedactedText() {
    String latency(int? value) => value == null ? '未收到' : '$value ms';
    return <String>[
      '即时翻译运行诊断（不含 Key、音频或对话内容）',
      '状态: ${phase.name}',
      '模式: ${mode == ConversationMode.simultaneous ? '同声传译' : '逐句翻译'}',
      '会话时长: $sessionDurationMilliseconds ms',
      '麦克风已发送块: $microphoneChunksSent',
      '回声保护丢弃块: $microphoneChunksSuppressed',
      '静音停发块: $microphoneChunksHeld',
      '检测到发言: $utterancesDetected',
      '抢话中断: $bargeIns',
      '逐句完成轮次: $sentenceTurnsCompleted',
      '自动方向切换: $autoDirectionSwitches',
      '耳机状态: $headsetState',
      '译音块 / 字节: $outputAudioChunks / $outputAudioBytes',
      '完成轮次: $completedTurns',
      '方向切换: $directionSwitches',
      '重连事件: $reconnectEvents',
      '会话错误: $sessionFailures',
      '播放错误: $playbackFailures'
          '${_formatFailureDetails(lastPlaybackFailureReason, lastPlaybackFailurePlatformCode)}',
      '系统音频中断: $audioInterruptions',
      'Gemini Token 输入 / 输出 / 合计: '
          '${geminiUsageAvailable ? '$geminiPromptTokens / $geminiResponseTokens / $geminiTotalTokens' : '未收到'}',
      '连接并开始聆听: ${latency(listeningReadyMilliseconds)}',
      '首个麦克风发送块: ${latency(firstMicrophoneSentMilliseconds)}',
      '首段原文（相对首个发送块）: '
          '${latency(firstSourceTextMilliseconds)}',
      '首段译文（相对首个发送块）: '
          '${latency(firstTranslatedTextMilliseconds)}',
      '首段译音（相对首个发送块）: '
          '${latency(firstTranslatedAudioMilliseconds)}',
      '最大 Dart 排队: $maximumScheduledPlaybackMilliseconds ms',
      '原生当前 / 上限排队: '
          '${playbackMetrics.queuedMilliseconds} / '
          '${playbackMetrics.maximumQueueMilliseconds} ms',
      '原生丢弃译音块: ${playbackMetrics.droppedChunks}',
      '当前输出路由: ${playbackMetrics.outputRoute.name}',
      '音频焦点已获得: ${playbackMetrics.audioFocusGranted ? '是' : '否'}',
      '原生指标可用: ${playbackMetricsAvailable ? '是' : '否'}',
    ].join('\n');
  }

  static String _formatFailureDetails(String? reason, int? platformCode) {
    if (reason == null && platformCode == null) {
      return '';
    }
    final List<String> parts = <String>[
      ?reason,
      if (platformCode != null) 'code=$platformCode',
    ];
    return '（最近: ${parts.join(' / ')}）';
  }
}
