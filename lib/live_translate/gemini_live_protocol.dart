import 'dart:convert';
import 'dart:typed_data';

import '../audio/audio_constants.dart';
import 'live_event.dart';

class GeminiLiveProtocol {
  const GeminiLiveProtocol._();

  static const String model = 'gemini-3.5-live-translate-preview';
  static const String endpoint =
      'wss://generativelanguage.googleapis.com/ws/'
      'google.ai.generativelanguage.v1beta.GenerativeService.'
      'BidiGenerateContent';

  static String setupMessage({
    required String targetLanguageCode,
    String? resumptionHandle,
  }) {
    final Map<String, Object?> setup = <String, Object?>{
      'model': 'models/$model',
      'generationConfig': <String, Object?>{
        'responseModalities': <String>['AUDIO'],
        'translationConfig': <String, Object?>{
          'targetLanguageCode': targetLanguageCode,
          'echoTargetLanguage': false,
        },
      },
      // The raw v1beta endpoint currently accepts transcription settings at
      // setup level. The SDK config flattens these fields the same way.
      'inputAudioTranscription': <String, Object?>{},
      'outputAudioTranscription': <String, Object?>{},
    };
    if (resumptionHandle != null) {
      setup['sessionResumption'] = <String, Object?>{
        'handle': resumptionHandle,
      };
    }
    return jsonEncode(<String, Object?>{'setup': setup});
  }

  static String audioMessage(Uint8List pcm) {
    return jsonEncode(<String, Object?>{
      'realtimeInput': <String, Object?>{
        'audio': <String, Object?>{
          'data': base64Encode(pcm),
          'mimeType': 'audio/pcm;rate=$inputSampleRateHz',
        },
      },
    });
  }

  static List<LiveEvent> parseServerMessage(String payload) {
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      return const <LiveEvent>[];
    }
    final Map<String, Object?>? message = _map(decoded);
    if (message == null) {
      return const <LiveEvent>[];
    }

    final List<LiveEvent> events = <LiveEvent>[];
    if (message.containsKey('setupComplete')) {
      events.add(const LivePhaseChanged(LiveSessionPhase.ready));
    }

    final Map<String, Object?>? resumption = _map(
      message['sessionResumptionUpdate'],
    );
    final bool resumable = resumption?['resumable'] == true;
    final String? newHandle = _string(resumption?['newHandle']);
    if (resumable && newHandle != null && newHandle.isNotEmpty) {
      events.add(LiveResumptionHandle(newHandle));
    }
    if (message.containsKey('goAway')) {
      events.add(const LiveGoAway());
    }

    final Map<String, Object?>? error = _map(message['error']);
    if (error != null) {
      final String status = _string(error['status']) ?? '';
      final int? code = error['code'] is int ? error['code'] as int : null;
      final bool authenticationFailure =
          code == 401 ||
          code == 403 ||
          status == 'UNAUTHENTICATED' ||
          status == 'PERMISSION_DENIED';
      events.add(
        LiveSessionFailure(
          userMessage: authenticationFailure
              ? 'API Key 无效或没有此模型的访问权限'
              : 'Gemini Live 会话返回错误，请稍后重试',
          authenticationFailure: authenticationFailure,
        ),
      );
    }

    final Map<String, Object?>? content = _map(message['serverContent']);
    if (content == null) {
      return events;
    }
    final Map<String, Object?>? input = _map(content['inputTranscription']);
    final String? inputText = _string(input?['text']);
    if (inputText != null && inputText.isNotEmpty) {
      events.add(
        LiveInputTranscript(inputText, _string(input?['languageCode'])),
      );
    }
    final Map<String, Object?>? output = _map(content['outputTranscription']);
    final String? outputText = _string(output?['text']);
    if (outputText != null && outputText.isNotEmpty) {
      events.add(
        LiveOutputTranscript(outputText, _string(output?['languageCode'])),
      );
    }

    final Map<String, Object?>? modelTurn = _map(content['modelTurn']);
    final Object? rawParts = modelTurn?['parts'];
    if (rawParts is List<Object?>) {
      for (final Object? rawPart in rawParts) {
        final Map<String, Object?>? part = _map(rawPart);
        final Map<String, Object?>? inlineData = _map(part?['inlineData']);
        final String? data = _string(inlineData?['data']);
        if (data == null || data.isEmpty) {
          continue;
        }
        try {
          events.add(LiveAudioChunk(base64Decode(data)));
        } on FormatException {
          // Ignore only the malformed audio part; transcript data remains useful.
        }
      }
    }
    if (content['interrupted'] == true) {
      events.add(const LiveInterrupted());
    }
    if (content['turnComplete'] == true) {
      events.add(const LiveTurnComplete());
    }
    return events;
  }

  static Map<String, Object?>? _map(Object? value) {
    if (value is Map<String, Object?>) {
      return value;
    }
    return null;
  }

  static String? _string(Object? value) => value is String ? value : null;
}
