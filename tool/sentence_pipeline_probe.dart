import 'dart:io';

import 'package:realtime_translation/conversation/sentence_translator.dart';
import 'package:realtime_translation/shared/translation_language.dart';

/// End-to-end probe of the 逐句翻译 pipeline (live ASR -> flash-lite
/// correct+translate) with the real APIs. Prints the transcript and the
/// translation; never prints the key.
Future<void> main(List<String> arguments) async {
  final String apiKey = Platform.environment['GEMINI_API_KEY']?.trim() ?? '';
  final String pcmPath = Platform.environment['LIVE_TEST_PCM']?.trim() ?? '';
  if (apiKey.isEmpty || pcmPath.isEmpty) {
    stderr.writeln('Set GEMINI_API_KEY and LIVE_TEST_PCM.');
    exitCode = 64;
    return;
  }
  final RestSentenceTranslator translator = RestSentenceTranslator();
  final Stopwatch stopwatch = Stopwatch()..start();
  try {
    final SentenceTextTranslation result = await translator.translate(
      apiKey: apiKey,
      sourceText: '你 好 , 请 问 这 家 酒 店 的 房 间 多 少 钱 一 晚 ? 早 餐 是 免 费 的 吗 ?',
      source: languageByCode('zh-Hans'),
      target: languageByCode('en'),
      context: const <SentenceContextTurn>[],
    );
    stdout.writeln('--- ${stopwatch.elapsedMilliseconds}ms');
    stdout.writeln('source: ${result.sourceText}');
    stdout.writeln('translation: ${result.translatedText}');
  } on Object catch (error) {
    stdout.writeln('PIPELINE FAILED: $error');
    exitCode = 1;
  }
}
