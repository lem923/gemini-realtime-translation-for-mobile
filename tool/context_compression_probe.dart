import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:realtime_translation/live_translate/live_event.dart';
import 'package:realtime_translation/live_translate/live_translation_session.dart';

/// Compares the default sliding-window config against the aggressive
/// `triggerTokens: 0` + `targetTokens: 0` config from the official AI Studio
/// examples on the real Live API. Prints counts and timing only; never logs
/// transcripts, audio, or keys.
Future<void> main(List<String> arguments) async {
  final String apiKey = Platform.environment['GEMINI_API_KEY']?.trim() ?? '';
  final String pcmPath = Platform.environment['LIVE_TEST_PCM']?.trim() ?? '';
  if (apiKey.isEmpty || pcmPath.isEmpty) {
    stderr.writeln(
      'Set GEMINI_API_KEY and LIVE_TEST_PCM (raw 16 kHz mono PCM16).',
    );
    exitCode = 64;
    return;
  }
  final Uint8List pcm = await File(pcmPath).readAsBytes();

  final Map<String, Object?> defaultResult = await _runProbe(
    apiKey: apiKey,
    pcm: pcm,
    label: 'default',
  );
  final Map<String, Object?> aggressiveResult = await _runProbe(
    apiKey: apiKey,
    pcm: pcm,
    label: 'aggressive-zero',
    slidingWindowTargetTokens: 0,
    compressionTriggerTokens: 0,
  );

  stdout.writeln('--- default: $defaultResult');
  stdout.writeln('--- aggressive-zero: $aggressiveResult');
}

Future<Map<String, Object?>> _runProbe({
  required String apiKey,
  required Uint8List pcm,
  required String label,
  int? slidingWindowTargetTokens,
  int? compressionTriggerTokens,
}) async {
  final Stopwatch stopwatch = Stopwatch()..start();
  final GeminiLiveSession session = GeminiLiveSession(
    apiKey: apiKey,
    targetLanguageCode: 'zh-Hans',
    slidingWindowTargetTokens: slidingWindowTargetTokens,
    compressionTriggerTokens: compressionTriggerTokens,
  );
  final List<Map<String, Object?>> compressionUpdates =
      <Map<String, Object?>>[];
  int inputTextChars = 0;
  int outputTextChars = 0;
  int outputAudioBytes = 0;
  int turnCompleteEvents = 0;
  String? failure;
  bool setupComplete = false;
  final Completer<void> completed = Completer<void>();
  final StreamSubscription<LiveEvent> subscription = session.events.listen((
    LiveEvent event,
  ) {
    switch (event) {
      case LivePhaseChanged(:final LiveSessionPhase phase):
        if (phase == LiveSessionPhase.ready) setupComplete = true;
      case LiveInputTranscript(:final String text):
        inputTextChars += text.length;
      case LiveOutputTranscript(:final String text):
        outputTextChars += text.length;
      case LiveAudioChunk(:final Uint8List bytes):
        outputAudioBytes += bytes.length;
      case LiveTurnComplete():
        turnCompleteEvents += 1;
        if (!completed.isCompleted) completed.complete();
      case LiveCompressionUpdate(:final Map<String, Object?> payload):
        compressionUpdates.add(payload);
      case LiveSessionFailure(:final String userMessage):
        failure = userMessage;
      default:
        break;
    }
  });

  try {
    await session.connect().timeout(const Duration(seconds: 25));
    final int connectMs = stopwatch.elapsedMilliseconds;
    const int chunkBytes = 3200;
    for (int offset = 0; offset < pcm.length; offset += chunkBytes) {
      final int end = (offset + chunkBytes).clamp(0, pcm.length);
      session.sendAudio(Uint8List.fromList(pcm.sublist(offset, end)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    session.endAudioStream();
    await completed.future.timeout(const Duration(seconds: 60));
    return <String, Object?>{
      'label': label,
      'setupComplete': setupComplete,
      'connectMs': connectMs,
      'totalMs': stopwatch.elapsedMilliseconds,
      'inputTextChars': inputTextChars,
      'outputTextChars': outputTextChars,
      'outputAudioBytes': outputAudioBytes,
      'turnCompleteEvents': turnCompleteEvents,
      'compressionUpdates': compressionUpdates
          .map((Map<String, Object?> update) => update.toString())
          .toList(),
      'failure': failure,
    };
  } catch (error) {
    return <String, Object?>{
      'label': label,
      'setupComplete': setupComplete,
      'totalMs': stopwatch.elapsedMilliseconds,
      'inputTextChars': inputTextChars,
      'outputTextChars': outputTextChars,
      'outputAudioBytes': outputAudioBytes,
      'turnCompleteEvents': turnCompleteEvents,
      'compressionUpdates': compressionUpdates.length,
      'failure': failure,
      'error': error.runtimeType.toString(),
    };
  } finally {
    await subscription.cancel();
    await session.close();
  }
}
