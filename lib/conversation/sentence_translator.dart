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

/// Streaming ASR session for 逐句翻译 push-to-talk: PCM streams to the
/// audio-native flash live model while the button is held, so the transcript
/// is ready almost immediately after release.
abstract interface class SentenceAsr {
  Future<void> connect();
  bool get isReady;
  String? get failure;
  void addPcm(Uint8List chunk);
  Future<String> finalize();
  Future<void> dispose();
}

class LiveApiSentenceAsr implements SentenceAsr {
  LiveApiSentenceAsr({
    required this.apiKey,
    this.model = 'gemini-3.1-flash-live-preview',
  });

  final String apiKey;
  final String model;

  static const int _transcriptionSettleMicros = 1500000;

  GeminiLiveSession? _session;
  StreamSubscription<LiveEvent>? _subscription;
  final StringBuffer _transcript = StringBuffer();
  int _lastGrowthMicros = 0;
  bool _ready = false;
  String? _failure;

  @override
  bool get isReady => _ready;

  @override
  String? get failure => _failure;

  @override
  Future<void> connect() async {
    if (_session != null) {
      return;
    }
    final GeminiLiveSession session = GeminiLiveSession(
      apiKey: apiKey,
      targetLanguageCode: 'en',
      model: model,
      translationEnabled: false,
    );
    _session = session;
    _subscription = session.events.listen((LiveEvent event) {
      switch (event) {
        case LiveInputTranscript(:final String text):
          _transcript.write(text);
          _lastGrowthMicros = DateTime.now().microsecondsSinceEpoch;
        case LiveSessionFailure(:final String userMessage):
          _failure = userMessage;
        case LivePhaseChanged(:final LiveSessionPhase phase):
          if (phase == LiveSessionPhase.ready) {
            _ready = true;
          } else if (phase == LiveSessionPhase.closed) {
            _ready = false;
          }
        default:
          break;
      }
    });
    await session.connect();
    _ready = true;
  }

  @override
  void addPcm(Uint8List chunk) {
    _session?.sendAudio(chunk);
  }

  @override
  Future<String> finalize() async {
    final GeminiLiveSession? session = _session;
    if (session == null) {
      throw const SentencePipelineException('语音识别会话未就绪');
    }
    session.endAudioStream();
    // The transcription settles quickly after the stream end.
    for (int i = 0; i < 40; i += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (_transcript.isNotEmpty &&
          DateTime.now().microsecondsSinceEpoch - _lastGrowthMicros >
              _transcriptionSettleMicros) {
        break;
      }
    }
    final String text = _transcript.toString().trim();
    if (_failure != null && text.isEmpty) {
      throw SentencePipelineException(_failure!);
    }
    if (text.isEmpty) {
      throw const SentencePipelineException('语音识别没有返回结果');
    }
    _transcript.clear();
    _lastGrowthMicros = 0;
    return text;
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _session?.close();
    _session = null;
    _ready = false;
  }
}

/// Text-only correction + translation for the 逐句翻译 pipeline.
abstract interface class SentenceTranslator {
  Future<SentenceTextTranslation> translate({
    required String apiKey,
    required String sourceText,
    required TranslationLanguage source,
    required TranslationLanguage target,
    required List<SentenceContextTurn> context,
  });
}

class RestSentenceTranslator implements SentenceTranslator {
  RestSentenceTranslator({
    this.textModel = 'gemini-flash-lite-latest',
    this.timeout = const Duration(seconds: 60),
  });

  final String textModel;
  final Duration timeout;

  @override
  Future<SentenceTextTranslation> translate({
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
      return SentenceTextTranslation(
        sourceText: sourceText,
        translatedText: sourceText,
      );
    }
    return SentenceTextTranslation(
      sourceText: sourceText,
      translatedText: text,
    );
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
