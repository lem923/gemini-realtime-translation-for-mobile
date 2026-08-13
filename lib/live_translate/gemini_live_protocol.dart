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
      'contextWindowCompression': <String, Object?>{
        'slidingWindow': <String, Object?>{},
      },
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

  static String audioStreamEndMessage() {
    return jsonEncode(<String, Object?>{
      'realtimeInput': <String, Object?>{'audioStreamEnd': true},
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
      final bool quotaFailure = code == 429 || status == 'RESOURCE_EXHAUSTED';
      final bool configurationFailure =
          code == 400 ||
          code == 404 ||
          status == 'INVALID_ARGUMENT' ||
          status == 'NOT_FOUND' ||
          status == 'FAILED_PRECONDITION';
      final bool retryable =
          !authenticationFailure &&
          !quotaFailure &&
          !configurationFailure &&
          (code == null || code >= 500 || status == 'UNAVAILABLE');
      final LiveFailureKind kind = authenticationFailure
          ? LiveFailureKind.authentication
          : quotaFailure
          ? LiveFailureKind.rateLimited
          : configurationFailure
          ? LiveFailureKind.configuration
          : LiveFailureKind.service;
      events.add(
        LiveSessionFailure(
          userMessage: authenticationFailure
              ? 'API Key 无效或没有此模型的访问权限'
              : quotaFailure
              ? 'Gemini API 配额或并发限制已达到，请稍后重试'
              : configurationFailure
              ? 'Gemini Live 模型或会话配置当前不可用'
              : 'Gemini Live 服务暂时不可用，正在重连',
          authenticationFailure: authenticationFailure,
          retryable: retryable,
          kind: kind,
        ),
      );
    }

    final Map<String, Object?>? usage = _map(message['usageMetadata']);
    if (usage != null) {
      events.add(
        LiveUsageMetadata(
          promptTokenCount: _nonNegativeInt(usage['promptTokenCount']),
          responseTokenCount: _nonNegativeInt(usage['responseTokenCount']),
          totalTokenCount: _nonNegativeInt(usage['totalTokenCount']),
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
        if (!_isOutputAudioMimeType(inlineData?['mimeType'])) {
          continue;
        }
        final String? data = _string(inlineData?['data']);
        if (data == null || data.isEmpty) {
          continue;
        }
        try {
          final Uint8List bytes = base64Decode(data);
          if (bytes.isNotEmpty) {
            events.add(LiveAudioChunk(bytes));
          }
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

  static bool _isOutputAudioMimeType(Object? value) {
    if (value is! String) {
      return false;
    }
    final List<String> sections = value.split(';');
    if (sections.isEmpty ||
        sections.first.trim().toLowerCase() != 'audio/pcm') {
      return false;
    }
    final Map<String, String> parameters = <String, String>{};
    for (final String section in sections.skip(1)) {
      final int separator = section.indexOf('=');
      if (separator <= 0 || separator == section.length - 1) {
        return false;
      }
      final String name = section.substring(0, separator).trim().toLowerCase();
      if (name != 'rate' && name != 'channels') {
        return false;
      }
      if (parameters.containsKey(name)) {
        return false;
      }
      final String parameterValue = section.substring(separator + 1).trim();
      if (parameterValue.isEmpty) {
        return false;
      }
      parameters[name] = parameterValue;
    }
    return parameters['rate'] == '24000' &&
        (parameters['channels'] == null || parameters['channels'] == '1');
  }

  static int _nonNegativeInt(Object? value) {
    final int? parsed = switch (value) {
      final int number => number,
      final String text => int.tryParse(text),
      _ => null,
    };
    return parsed == null || parsed < 0 ? 0 : parsed;
  }
}
