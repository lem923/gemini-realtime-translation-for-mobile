import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_translation/live_translate/gemini_live_protocol.dart';
import 'package:realtime_translation/live_translate/live_event.dart';

void main() {
  test('setup enables audio translation and both transcripts', () {
    final Object? decoded = jsonDecode(
      GeminiLiveProtocol.setupMessage(targetLanguageCode: 'ja'),
    );
    final Map<String, Object?> root = decoded! as Map<String, Object?>;
    final Map<String, Object?> setup = root['setup']! as Map<String, Object?>;
    final Map<String, Object?> generation =
        setup['generationConfig']! as Map<String, Object?>;
    final Map<String, Object?> translation =
        generation['translationConfig']! as Map<String, Object?>;

    expect(setup['model'], 'models/gemini-3.5-live-translate-preview');
    expect(generation['responseModalities'], <String>['AUDIO']);
    expect(setup, contains('inputAudioTranscription'));
    expect(setup, contains('outputAudioTranscription'));
    expect(setup['contextWindowCompression'], <String, Object?>{
      'slidingWindow': <String, Object?>{},
    });
    expect(generation, isNot(contains('inputAudioTranscription')));
    expect(generation, isNot(contains('outputAudioTranscription')));
    expect(setup, isNot(contains('sessionResumption')));
    expect(translation['targetLanguageCode'], 'ja');
    expect(translation['echoTargetLanguage'], isFalse);
  });

  test('audio message contains 16 kHz base64 PCM', () {
    final Uint8List bytes = Uint8List.fromList(<int>[0, 1, 2, 3]);
    final Map<String, Object?> root =
        jsonDecode(GeminiLiveProtocol.audioMessage(bytes))
            as Map<String, Object?>;
    final Map<String, Object?> realtime =
        root['realtimeInput']! as Map<String, Object?>;
    final Map<String, Object?> audio =
        realtime['audio']! as Map<String, Object?>;
    expect(audio['mimeType'], 'audio/pcm;rate=16000');
    expect(audio['data'], base64Encode(bytes));
  });

  test('parses transcripts, audio, and turn completion', () {
    final String message = jsonEncode(<String, Object?>{
      'serverContent': <String, Object?>{
        'inputTranscription': <String, Object?>{
          'text': 'hello',
          'languageCode': 'en',
        },
        'outputTranscription': <String, Object?>{
          'text': '你好',
          'languageCode': 'zh-Hans',
        },
        'modelTurn': <String, Object?>{
          'parts': <Object?>[
            <String, Object?>{
              'inlineData': <String, Object?>{
                'data': base64Encode(<int>[1, 2, 3, 4]),
                'mimeType': 'audio/pcm;rate=24000',
              },
            },
          ],
        },
        'turnComplete': true,
      },
    });

    final List<LiveEvent> events = GeminiLiveProtocol.parseServerMessage(
      message,
    );
    expect(events.whereType<LiveInputTranscript>(), hasLength(1));
    expect(events.whereType<LiveOutputTranscript>(), hasLength(1));
    expect(events.whereType<LiveAudioChunk>().single.bytes, <int>[1, 2, 3, 4]);
    expect(events.whereType<LiveTurnComplete>(), hasLength(1));
  });

  test('parses redacted token usage with defensive numeric handling', () {
    final LiveUsageMetadata usage = GeminiLiveProtocol.parseServerMessage(
      jsonEncode(<String, Object?>{
        'usageMetadata': <String, Object?>{
          'promptTokenCount': '125',
          'responseTokenCount': 30,
          'totalTokenCount': 155,
        },
      }),
    ).whereType<LiveUsageMetadata>().single;

    expect(usage.promptTokenCount, 125);
    expect(usage.responseTokenCount, 30);
    expect(usage.totalTokenCount, 155);

    final LiveUsageMetadata malformed = GeminiLiveProtocol.parseServerMessage(
      jsonEncode(<String, Object?>{
        'usageMetadata': <String, Object?>{
          'promptTokenCount': -1,
          'responseTokenCount': 'not-a-number',
        },
      }),
    ).whereType<LiveUsageMetadata>().single;
    expect(malformed.promptTokenCount, 0);
    expect(malformed.responseTokenCount, 0);
    expect(malformed.totalTokenCount, 0);
  });

  test('classifies authentication and quota errors as terminal', () {
    final LiveSessionFailure authentication =
        GeminiLiveProtocol.parseServerMessage(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{
              'code': 403,
              'status': 'PERMISSION_DENIED',
            },
          }),
        ).whereType<LiveSessionFailure>().single;
    final LiveSessionFailure quota = GeminiLiveProtocol.parseServerMessage(
      jsonEncode(<String, Object?>{
        'error': <String, Object?>{'code': 429, 'status': 'RESOURCE_EXHAUSTED'},
      }),
    ).whereType<LiveSessionFailure>().single;

    expect(authentication.authenticationFailure, isTrue);
    expect(authentication.kind, LiveFailureKind.authentication);
    expect(authentication.retryable, isFalse);
    expect(quota.authenticationFailure, isFalse);
    expect(quota.kind, LiveFailureKind.rateLimited);
    expect(quota.retryable, isFalse);
    expect(quota.userMessage, contains('配额'));
  });

  test('classifies temporary server errors as retryable', () {
    final LiveSessionFailure failure = GeminiLiveProtocol.parseServerMessage(
      jsonEncode(<String, Object?>{
        'error': <String, Object?>{'code': 503, 'status': 'UNAVAILABLE'},
      }),
    ).whereType<LiveSessionFailure>().single;

    expect(failure.authenticationFailure, isFalse);
    expect(failure.kind, LiveFailureKind.service);
    expect(failure.retryable, isTrue);
    expect(failure.userMessage, contains('重连'));
  });
}
