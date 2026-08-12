import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:realtime_translation/live_translate/live_event.dart';
import 'package:realtime_translation/live_translate/live_translation_session.dart';

Future<void> main(List<String> arguments) async {
  final String apiKey = Platform.environment['GEMINI_API_KEY']?.trim() ?? '';
  final String pcmPath = Platform.environment['LIVE_TEST_PCM']?.trim() ?? '';
  final String target =
      Platform.environment['LIVE_TEST_TARGET']?.trim() ?? 'zh-Hans';
  final Uri endpoint = Uri.parse('wss://generativelanguage.googleapis.com/ws');
  stdout.writeln(
    'proxy_configured=${HttpClient.findProxyFromEnvironment(endpoint.replace(scheme: 'https')) != 'DIRECT'}',
  );
  if (apiKey.isEmpty || pcmPath.isEmpty) {
    stderr.writeln(
      'Set GEMINI_API_KEY and LIVE_TEST_PCM (raw 16 kHz mono PCM16).',
    );
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
  final Completer<void> completed = Completer<void>();
  int inputTranscriptCharacters = 0;
  int outputTranscriptCharacters = 0;
  int outputAudioBytes = 0;
  int promptTokens = 0;
  int responseTokens = 0;
  int totalTokens = 0;
  bool setupComplete = false;
  bool audioSent = false;
  String? failure;
  void completeWhenOutputArrives() {
    if (inputTranscriptCharacters > 0 &&
        outputTranscriptCharacters > 0 &&
        outputAudioBytes > 0 &&
        !completed.isCompleted) {
      completed.complete();
    }
  }

  final StreamSubscription<LiveEvent> subscription = session.events.listen((
    LiveEvent event,
  ) {
    switch (event) {
      case LivePhaseChanged(:final LiveSessionPhase phase):
        if (phase == LiveSessionPhase.ready) setupComplete = true;
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
        promptTokens += event.promptTokenCount;
        responseTokens += event.responseTokenCount;
        totalTokens += event.totalTokenCount;
      case LiveTurnComplete():
        if (!completed.isCompleted) completed.complete();
      case LiveSessionFailure(:final String userMessage):
        failure = userMessage;
      default:
        break;
    }
  });

  try {
    await session.connect();
    final Uint8List pcm = await pcmFile.readAsBytes();
    const int chunkBytes = 3200;
    for (int offset = 0; offset < pcm.length; offset += chunkBytes) {
      final int end = (offset + chunkBytes).clamp(0, pcm.length);
      session.sendAudio(Uint8List.fromList(pcm.sublist(offset, end)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    audioSent = true;
    await completed.future.timeout(const Duration(seconds: 45));
    final bool passed =
        failure == null &&
        inputTranscriptCharacters > 0 &&
        outputTranscriptCharacters > 0 &&
        outputAudioBytes > 0;
    stdout.writeln(
      'live_smoke passed=$passed '
      'input_text_chars=$inputTranscriptCharacters '
      'output_text_chars=$outputTranscriptCharacters '
      'output_audio_bytes=$outputAudioBytes '
      'prompt_tokens=$promptTokens '
      'response_tokens=$responseTokens '
      'total_tokens=$totalTokens',
    );
    if (!passed) exitCode = 1;
  } on Object catch (error) {
    stderr.writeln(
      'live_smoke failed '
      'setup_complete=$setupComplete '
      'audio_sent=$audioSent '
      'server_failure=${failure != null} '
      'failure_message=${failure ?? 'none'} '
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
