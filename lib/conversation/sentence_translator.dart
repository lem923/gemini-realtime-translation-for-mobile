import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../live_translate/live_event.dart';
import '../live_translate/live_translation_session.dart';
import '../shared/translation_language.dart';

/// One completed sentence turn used as context for the next correction.
class SentenceContextTurn {
  const SentenceContextTurn({
    required this.sourceLanguageCode,
    required this.sourceText,
    required this.translatedText,
    required this.createdAt,
  });

  final String sourceLanguageCode;
  final String sourceText;
  final String translatedText;
  final DateTime createdAt;
}

class SentenceTextTranslation {
  const SentenceTextTranslation({
    required this.sourceText,
    required this.translatedText,
  });

  final String sourceText;
  final String translatedText;
}

/// Two-stage offline sentence pipeline for 逐句翻译:
/// 1. ASR with a model that accepts inline audio (gemini-2.5-pro verified).
/// 2. Correct + translate with a cheap text model, using a short context
///    window to repair disfluencies and accents.
/// The caller then plays [SentenceTranslation.pcm] (system TTS output).
abstract interface class SentenceTranslator {
  Future<SentenceTextTranslation> translate({
    required String apiKey,
    required Uint8List pcm,
    required TranslationLanguage source,
    required TranslationLanguage target,
    required List<SentenceContextTurn> context,
  });
}

class RestSentenceTranslator implements SentenceTranslator {
  RestSentenceTranslator({
    // The flash live family is audio-native and cheap; the preview suffix is
    // required on current keys. Text correction uses the latest lite alias.
    this.asrModel = 'gemini-3.1-flash-live-preview',
    this.textModel = 'gemini-flash-lite-latest',
    this.timeout = const Duration(seconds: 60),
  });

  static const int _transcriptionSettleMicros = 1500000;

  final String asrModel;
  final String textModel;
  final Duration timeout;

  @override
  @override
  Future<SentenceTextTranslation> translate({
    required String apiKey,
    required Uint8List pcm,
    required TranslationLanguage source,
    required TranslationLanguage target,
    required List<SentenceContextTurn> context,
  }) async {
    final String sourceText = await _transcribe(apiKey: apiKey, pcm: pcm);
    final String translation = await _correctAndTranslate(
      apiKey: apiKey,
      sourceText: sourceText,
      source: source,
      target: target,
      context: context,
    );
    return SentenceTextTranslation(
      sourceText: sourceText,
      translatedText: translation,
    );
  }

  /// Transcribes the recorded PCM with the audio-native flash live model.
  /// The session is opened per turn (1-2 s), the buffered audio is streamed at
  /// real-time pace, and the growing input transcription is accumulated.
  Future<String> _transcribe({
    required String apiKey,
    required Uint8List pcm,
  }) async {
    final GeminiLiveSession session = GeminiLiveSession(
      apiKey: apiKey,
      targetLanguageCode: 'en',
      model: asrModel,
      translationEnabled: false,
    );
    final StringBuffer transcript = StringBuffer();
    String? failure;
    int lastGrowthMicros = 0;
    final StreamSubscription<LiveEvent> subscription = session.events.listen((
      LiveEvent event,
    ) {
      switch (event) {
        case LiveInputTranscript(:final String text):
          transcript.write(text);
          lastGrowthMicros = DateTime.now().microsecondsSinceEpoch;
        case LiveSessionFailure(:final String userMessage):
          failure = userMessage;
        default:
          break;
      }
    });
    try {
      await session.connect().timeout(timeout);
      const int chunkBytes = 3200;
      for (int offset = 0; offset < pcm.length; offset += chunkBytes) {
        final int end = (offset + chunkBytes).clamp(0, pcm.length);
        session.sendAudio(Uint8List.fromList(pcm.sublist(offset, end)));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      session.endAudioStream();
      // The transcription settles quickly after the stream end; stop once it
      // has not grown for a moment instead of waiting a fixed window.
      for (int i = 0; i < 40; i += 1) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final int sinceGrowth =
            DateTime.now().microsecondsSinceEpoch - lastGrowthMicros;
        if (transcript.isNotEmpty && sinceGrowth > _transcriptionSettleMicros) {
          break;
        }
      }
      final String text = transcript.toString().trim();
      if (failure != null && text.isEmpty) {
        throw SentencePipelineException(failure!);
      }
      if (text.isEmpty) {
        throw const SentencePipelineException('语音识别没有返回结果');
      }
      return text;
    } finally {
      await subscription.cancel();
      await session.close();
    }
  }

  Future<String> _correctAndTranslate({
    required String apiKey,
    required String sourceText,
    required TranslationLanguage source,
    required TranslationLanguage target,
    required List<SentenceContextTurn> context,
  }) async {
    final StringBuffer system = StringBuffer();
    system
      ..writeln(
        '你是旅行翻译助手。把语音转写文本从'
        '${source.name}翻译成${target.name}。',
      )
      ..writeln(
        '要求：修正转写中的口癖、口音或残缺导致的错误（结合上下文推断原意），'
        '输出自然、地道的译文。只输出译文，不要解释。',
      );
    if (context.isNotEmpty) {
      system.writeln('最近对话上下文（可能包含错别字）：');
      for (final SentenceContextTurn turn in context) {
        system.writeln('${turn.sourceLanguageCode} 原文：${turn.sourceText}');
        system.writeln('译文：${turn.translatedText}');
      }
    }
    final Map<String, Object?> body = <String, Object?>{
      'systemInstruction': <String, Object?>{
        'parts': <Object?>[
          <String, Object?>{'text': system.toString()},
        ],
      },
      'contents': <Object?>[
        <String, Object?>{
          'parts': <Object?>[
            <String, Object?>{'text': sourceText},
          ],
        },
      ],
    };
    final String raw = await _post(apiKey, '$textModel:generateContent', body);
    final String text = _extractText(raw).trim();
    if (text.isEmpty) {
      // Fall back to the raw source text when the model returns nothing.
      return sourceText;
    }
    return text;
  }

  Future<String> _post(
    String apiKey,
    String path,
    Map<String, Object?> body,
  ) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client
          .postUrl(
            Uri.parse(
              'https://generativelanguage.googleapis.com/v1beta/models/$path',
            ),
          )
          .timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.headers.set('x-goog-api-key', apiKey);
      request.add(utf8.encode(jsonEncode(body)));
      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      final String raw = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw HttpException('Gemini REST ${response.statusCode}: $raw');
      }
      return raw;
    } on TimeoutException {
      throw const SentencePipelineException('请求超时');
    } finally {
      client.close(force: true);
    }
  }

  static String _extractText(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      final Map<String, Object?>? map = decoded as Map<String, Object?>?;
      final Object? error = map?['error'];
      if (error is Map<String, Object?>) {
        throw HttpException('${error['code']} ${error['message']}');
      }
      final List<Object?>? candidates = map?['candidates'] as List<Object?>?;
      if (candidates == null || candidates.isEmpty) {
        return '';
      }
      final Map<String, Object?>? content =
          (candidates.first as Map<String, Object?>?)?['content']
              as Map<String, Object?>?;
      final List<Object?>? parts = content?['parts'] as List<Object?>?;
      if (parts == null) {
        return '';
      }
      final StringBuffer buffer = StringBuffer();
      for (final Object? part in parts) {
        final Object? text = (part as Map<String, Object?>?)?['text'];
        if (text is String) {
          buffer.write(text);
        }
      }
      return buffer.toString();
    } on FormatException {
      return '';
    }
  }
}

class SentencePipelineException implements Exception {
  const SentencePipelineException(this.message);
  final String message;

  @override
  String toString() => message;
}
