import 'dart:typed_data';

enum LiveSessionPhase { connecting, ready, reconnecting, closed }

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

class LiveGoAway extends LiveEvent {
  const LiveGoAway();
}

class LiveSessionFailure extends LiveEvent {
  const LiveSessionFailure({
    required this.userMessage,
    required this.authenticationFailure,
    required this.retryable,
  });

  final String userMessage;
  final bool authenticationFailure;
  final bool retryable;
}
