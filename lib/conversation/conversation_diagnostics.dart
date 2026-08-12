import 'package:flutter/foundation.dart';

import '../audio/pcm_playback_gateway.dart';
import 'conversation_models.dart';

@immutable
class ConversationDiagnostics {
  const ConversationDiagnostics({
    required this.phase,
    required this.sessionDurationMilliseconds,
    required this.microphoneChunksSent,
    required this.microphoneChunksSuppressed,
    required this.outputAudioChunks,
    required this.outputAudioBytes,
    required this.completedTurns,
    required this.directionSwitches,
    required this.reconnectEvents,
    required this.sessionFailures,
    required this.playbackFailures,
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
  final int sessionDurationMilliseconds;
  final int microphoneChunksSent;
  final int microphoneChunksSuppressed;
  final int outputAudioChunks;
  final int outputAudioBytes;
  final int completedTurns;
  final int directionSwitches;
  final int reconnectEvents;
  final int sessionFailures;
  final int playbackFailures;
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
      '会话时长: $sessionDurationMilliseconds ms',
      '麦克风已发送块: $microphoneChunksSent',
      '回声保护丢弃块: $microphoneChunksSuppressed',
      '译音块 / 字节: $outputAudioChunks / $outputAudioBytes',
      '完成轮次: $completedTurns',
      '方向切换: $directionSwitches',
      '重连事件: $reconnectEvents',
      '会话错误: $sessionFailures',
      '播放错误: $playbackFailures',
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
      '原生指标可用: ${playbackMetricsAvailable ? '是' : '否'}',
    ].join('\n');
  }
}
