import 'dart:typed_data';

enum LiveSessionPhase { connecting, ready, reconnecting, closed }

enum LiveFailureKind {
  authentication,
  rateLimited,
  offline,
  configuration,
  service,
  unknown,
}

sealed class LiveEvent {
  const LiveEvent();
}

class LivePhaseChanged extends LiveEvent {
  const LivePhaseChanged(this.phase);
  final LiveSessionPhase phase;
}

class LiveInputTranscript extends LiveEvent {
  const LiveInputTranscript(this.text, this.languageCode);
  final String text;
  final String? languageCode;
}

class LiveOutputTranscript extends LiveEvent {
  const LiveOutputTranscript(this.text, this.languageCode);
  final String text;
  final String? languageCode;
}

class LiveAudioChunk extends LiveEvent {
  const LiveAudioChunk(this.bytes);
  final Uint8List bytes;
}

class LiveTurnComplete extends LiveEvent {
  const LiveTurnComplete();
}

class LiveInterrupted extends LiveEvent {
  const LiveInterrupted();
}

class LiveResumptionHandle extends LiveEvent {
  const LiveResumptionHandle(this.handle);
  final String handle;
}

class LiveCompressionUpdate extends LiveEvent {
  const LiveCompressionUpdate(this.payload);
  final Map<String, Object?> payload;
}

class LiveGoAway extends LiveEvent {
  const LiveGoAway();
}

class LiveUsageMetadata extends LiveEvent {
  const LiveUsageMetadata({
    required this.promptTokenCount,
    required this.responseTokenCount,
    required this.totalTokenCount,
  });

  final int promptTokenCount;
  final int responseTokenCount;
  final int totalTokenCount;
}

class LiveSessionFailure extends LiveEvent {
  const LiveSessionFailure({
    required this.userMessage,
    required this.authenticationFailure,
    required this.retryable,
    this.kind = LiveFailureKind.unknown,
  });

  final String userMessage;
  final bool authenticationFailure;
  final bool retryable;
  final LiveFailureKind kind;
}
