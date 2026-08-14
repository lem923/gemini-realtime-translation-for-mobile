import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
    this.asrModel = 'gemini-2.5-pro',
    this.textModel = 'gemini-2.5-flash-lite',
    this.timeout = const Duration(seconds: 60),
  });

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

  Future<String> _transcribe({
    required String apiKey,
    required Uint8List pcm,
  }) async {
    final Map<String, Object?> body = <String, Object?>{
      'contents': <Object?>[
        <String, Object?>{
          'parts': <Object?>[
            <String, Object?>{
              'inlineData': <String, Object?>{
                'mimeType': 'audio/wav',
                'data': base64Encode(_pcmToWav(pcm)),
              },
            },
            <String, Object?>{'text': '逐字转写这段语音，只输出转写文字。'},
          ],
        },
      ],
    };
    final String raw = await _post(apiKey, '$asrModel:generateContent', body);
    return _extractText(raw).trim();
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

  static Uint8List _pcmToWav(Uint8List pcm) {
    final Uint8List wav = Uint8List(44 + pcm.length);
    final ByteData header = ByteData.sublistView(wav);
    header.setUint32(0, 0x52494646, Endian.little); // RIFF
    header.setUint32(4, 36 + pcm.length, Endian.little);
    header.setUint32(8, 0x57415645, Endian.little); // WAVE
    header.setUint32(12, 0x666d7420, Endian.little); // fmt
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, 16000, Endian.little);
    header.setUint32(28, 16000 * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    header.setUint32(36, 0x64617461, Endian.little); // data
    header.setUint32(40, pcm.length, Endian.little);
    wav.setRange(44, wav.length, pcm);
    return wav;
  }
}

class SentencePipelineException implements Exception {
  const SentencePipelineException(this.message);
  final String message;

  @override
  String toString() => message;
}
