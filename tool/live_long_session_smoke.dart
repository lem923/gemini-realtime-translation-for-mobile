import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:realtime_translation/live_translate/live_event.dart';
import 'package:realtime_translation/live_translate/live_translation_session.dart';

Future<void> main(List<String> arguments) async {
  final String apiKey = Platform.environment['GEMINI_API_KEY']?.trim() ?? '';
  final String pcmPath = Platform.environment['LIVE_TEST_PCM']?.trim() ?? '';
  final String target =
      Platform.environment['LIVE_TEST_TARGET']?.trim() ?? 'en';
  final int? idleSeconds = int.tryParse(
    Platform.environment['LIVE_TEST_IDLE_SECONDS']?.trim() ?? '1260',
  );
  if (apiKey.isEmpty || pcmPath.isEmpty || idleSeconds == null) {
    stderr.writeln(
      'Set GEMINI_API_KEY, LIVE_TEST_PCM, and an integer '
      'LIVE_TEST_IDLE_SECONDS (default 1260).',
    );
    exitCode = 64;
    return;
  }
  if (idleSeconds < 0) {
    stderr.writeln('LIVE_TEST_IDLE_SECONDS must not be negative.');
    exitCode = 64;
    return;
  }
  final File pcmFile = File(pcmPath);
  if (!pcmFile.existsSync()) {
    stderr.writeln('LIVE_TEST_PCM does not exist.');
    exitCode = 66;
    return;
  }

  final GeminiLiveSession session = GeminiLiveSession(
    apiKey: apiKey,
    targetLanguageCode: target,
  );
  final Completer<void> outputComplete = Completer<void>();
  Completer<void>? readyWaiter;
  int readyEvents = 0;
  int reconnectEvents = 0;
  int failureEvents = 0;
  int inputTranscriptCharacters = 0;
  int outputTranscriptCharacters = 0;
  int outputAudioBytes = 0;
  int promptTokens = 0;
  int responseTokens = 0;
  int totalTokens = 0;

  void completeWhenOutputArrives() {
    if (inputTranscriptCharacters > 0 &&
        outputTranscriptCharacters > 0 &&
        outputAudioBytes > 0 &&
        !outputComplete.isCompleted) {
      outputComplete.complete();
    }
  }

  final StreamSubscription<LiveEvent> subscription = session.events.listen((
    LiveEvent event,
  ) {
    switch (event) {
      case LivePhaseChanged(:final LiveSessionPhase phase):
        if (phase == LiveSessionPhase.ready) {
          readyEvents += 1;
          final Completer<void>? waiter = readyWaiter;
          if (waiter != null && !waiter.isCompleted) {
            waiter.complete();
          }
        } else if (phase == LiveSessionPhase.reconnecting) {
          reconnectEvents += 1;
        }
      case LiveInputTranscript(:final String text):
        inputTranscriptCharacters += text.length;
        completeWhenOutputArrives();
      case LiveOutputTranscript(:final String text):
        outputTranscriptCharacters += text.length;
        completeWhenOutputArrives();
      case LiveAudioChunk(:final Uint8List bytes):
        outputAudioBytes += bytes.length;
        completeWhenOutputArrives();
      case LiveUsageMetadata():
        promptTokens = event.promptTokenCount;
        responseTokens = event.responseTokenCount;
        totalTokens = event.totalTokenCount;
      case LiveSessionFailure():
        failureEvents += 1;
      default:
        break;
    }
  });

  try {
    await session.connect();
    final Stopwatch idleWatch = Stopwatch()..start();
    while (idleWatch.elapsed.inSeconds < idleSeconds) {
      final int remaining = idleSeconds - idleWatch.elapsed.inSeconds;
      await Future<void>.delayed(Duration(seconds: remaining.clamp(1, 60)));
      stdout.writeln(
        'long_session_progress '
        'elapsed_seconds=${idleWatch.elapsed.inSeconds.clamp(0, idleSeconds)} '
        'ready=${session.isReady} '
        'ready_events=$readyEvents '
        'reconnect_events=$reconnectEvents '
        'failure_events=$failureEvents',
      );
    }

    if (!session.isReady) {
      readyWaiter = Completer<void>();
      if (!session.isReady) {
        await readyWaiter.future.timeout(const Duration(seconds: 45));
      }
    }

    final Uint8List pcm = await pcmFile.readAsBytes();
    const int chunkBytes = 3200;
    for (int offset = 0; offset < pcm.length; offset += chunkBytes) {
      final int end = (offset + chunkBytes).clamp(0, pcm.length);
      session.sendAudio(Uint8List.fromList(pcm.sublist(offset, end)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await outputComplete.future.timeout(const Duration(seconds: 45));

    final bool passed =
        session.isReady &&
        inputTranscriptCharacters > 0 &&
        outputTranscriptCharacters > 0 &&
        outputAudioBytes > 0 &&
        failureEvents == 0;
    stdout.writeln(
      'long_session_smoke passed=$passed '
      'idle_seconds=$idleSeconds '
      'ready_events=$readyEvents '
      'reconnect_events=$reconnectEvents '
      'failure_events=$failureEvents '
      'input_text_chars=$inputTranscriptCharacters '
      'output_text_chars=$outputTranscriptCharacters '
      'output_audio_bytes=$outputAudioBytes '
      'prompt_tokens=$promptTokens '
      'response_tokens=$responseTokens '
      'total_tokens=$totalTokens',
    );
    if (!passed) {
      exitCode = 1;
    }
  } on Object catch (error) {
    stderr.writeln(
      'long_session_smoke failed '
      'idle_seconds=$idleSeconds '
      'ready=${session.isReady} '
      'ready_events=$readyEvents '
      'reconnect_events=$reconnectEvents '
      'failure_events=$failureEvents '
      'input_text_chars=$inputTranscriptCharacters '
      'output_text_chars=$outputTranscriptCharacters '
      'output_audio_bytes=$outputAudioBytes '
      'error_type=${error.runtimeType}',
    );
    exitCode = 1;
  } finally {
    await subscription.cancel();
    await session.close();
  }
}
