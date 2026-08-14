import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:realtime_translation/live_translate/live_event.dart';
import 'package:realtime_translation/live_translate/live_translation_session.dart';

/// Focused probe: does a live model deliver inputTranscription for uploaded
/// PCM? Prints counts and the transcript (explicit developer probe).
Future<void> main(List<String> arguments) async {
  final String apiKey = Platform.environment['GEMINI_API_KEY']?.trim() ?? '';
  final String pcmPath = Platform.environment['LIVE_TEST_PCM']?.trim() ?? '';
  final String model = arguments.isNotEmpty
      ? arguments.first
      : 'gemini-3.1-flash-live-preview';
  if (apiKey.isEmpty || pcmPath.isEmpty) {
    stderr.writeln('Set GEMINI_API_KEY and LIVE_TEST_PCM.');
    exitCode = 64;
    return;
  }
  final GeminiLiveSession session = GeminiLiveSession(
    apiKey: apiKey,
    targetLanguageCode: 'en',
    model: model,
    translationEnabled: false,
  );
  final Stopwatch stopwatch = Stopwatch()..start();
  final StringBuffer transcript = StringBuffer();
  final StringBuffer outputText = StringBuffer();
  String? failure;
  bool ready = false;
  final StreamSubscription<LiveEvent> subscription = session.events.listen((
    LiveEvent event,
  ) {
    switch (event) {
      case LivePhaseChanged(:final LiveSessionPhase phase):
        if (phase == LiveSessionPhase.ready) ready = true;
      case LiveInputTranscript(:final String text):
        transcript.write(text);
      case LiveOutputTranscript(:final String text):
        outputText.write(text);
      case LiveSessionFailure(:final String userMessage):
        failure = userMessage;
      default:
        break;
    }
  });

  try {
    await session.connect().timeout(const Duration(seconds: 25));
    final Uint8List pcm = await File(pcmPath).readAsBytes();
    const int chunkBytes = 3200;
    for (int offset = 0; offset < pcm.length; offset += chunkBytes) {
      final int end = (offset + chunkBytes).clamp(0, pcm.length);
      session.sendAudio(Uint8List.fromList(pcm.sublist(offset, end)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    session.endAudioStream();
    await Future<void>.delayed(const Duration(seconds: 20));
    stdout.writeln(
      'model=$model ready=$ready inputTranscriptChars='
      '${transcript.length} transcript="$transcript" '
      'outputTextChars=${outputText.length} failure=$failure '
      'elapsed=${stopwatch.elapsedMilliseconds}ms',
    );
  } on Object catch (error) {
    stdout.writeln('model=$model ERROR: $error');
  } finally {
    await subscription.cancel();
    await session.close();
  }
}
