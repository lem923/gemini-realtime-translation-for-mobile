import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Probes the text-only REST pipeline used by 逐句翻译: audio transcription
/// (ASR) and correct+translate on cheap models. Prints counts and timing only;
/// never prints the key. Transcripts are printed because this is an explicit
/// developer probe of recognition quality.
Future<void> main(List<String> arguments) async {
  final String apiKey = Platform.environment['GEMINI_API_KEY']?.trim() ?? '';
  final String pcmPath = Platform.environment['LIVE_TEST_PCM']?.trim() ?? '';
  if (apiKey.isEmpty || pcmPath.isEmpty) {
    stderr.writeln(
      'Set GEMINI_API_KEY and LIVE_TEST_PCM (raw 16 kHz mono PCM16).',
    );
    exitCode = 64;
    return;
  }
  final String pcm = (await File(
    pcmPath,
  ).readAsBytes()).map((int b) => String.fromCharCode(b)).join();

  final List<String> models = arguments.isEmpty
      ? <String>['gemini-flash-lite-latest']
      : arguments;
  for (final String model in models) {
    await _probe(model, apiKey, pcm);
  }
}

Future<void> _probe(String model, String apiKey, String pcm) async {
  final Stopwatch stopwatch = Stopwatch()..start();
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
          <String, Object?>{'text': '请把这段语音转写为文字，只输出转写结果。'},
        ],
      },
    ],
    'generationConfig': <String, Object?>{
      'responseModalities': <String>['TEXT'],
    },
  };
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(
      Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/'
        '$model:generateContent',
      ),
    );
    request.headers.contentType = ContentType.json;
    request.headers.set('x-goog-api-key', apiKey);
    request.add(utf8.encode(jsonEncode(body)));
    final HttpClientResponse response = await request.close();
    final String raw = await response.transform(utf8.decoder).join();
    final Object? decoded = jsonDecode(raw);
    final Map<String, Object?>? error =
        (decoded as Map<String, Object?>?)?['error'] as Map<String, Object?>?;
    if (error != null) {
      stdout.writeln(
        '--- $model: ERROR ${error['code']} ${error['message']} '
        '(${stopwatch.elapsedMilliseconds}ms)',
      );
      return;
    }
    final String text = _extractText(decoded);
    stdout.writeln('--- $model: ${stopwatch.elapsedMilliseconds}ms -> "$text"');
  } on Object catch (error) {
    stdout.writeln('--- $model: FAILED $error');
  } finally {
    client.close(force: true);
  }
}

String _extractText(Object? decoded) {
  final List<Object?>? candidates =
      (decoded as Map<String, Object?>?)?.containsKey('candidates') == true
      ? (decoded as Map<String, Object?>)['candidates'] as List<Object?>?
      : null;
  if (candidates == null || candidates.isEmpty) {
    return '';
  }
  final Map<String, Object?>? content =
      candidates.first as Map<String, Object?>?;
  final List<Object?>? parts = content?['content'] == null
      ? null
      : ((content?['content'] as Map<String, Object?>)['parts']
            as List<Object?>?);
  if (parts == null) {
    return '';
  }
  final StringBuffer buffer = StringBuffer();
  for (final Object? part in parts) {
    final Object? text =
        (part as Map<String, Object?>?)?.containsKey('text') == true
        ? (part as Map<String, Object?>)['text']
        : null;
    if (text is String) {
      buffer.write(text);
    }
  }
  return buffer.toString();
}

/// Wraps raw 16 kHz mono PCM16 into a WAV container (44-byte header).
Uint8List _pcmToWav(String pcm) {
  final List<int> raw = pcm.codeUnits;
  final int byteRate = 16000 * 2 * 1;
  final Uint8List wav = Uint8List(44 + raw.length);
  final ByteData header = ByteData.sublistView(wav);
  header.setUint32(0, 0x52494646, Endian.little); // RIFF
  header.setUint32(4, 36 + raw.length, Endian.little);
  header.setUint32(8, 0x57415645, Endian.little); // WAVE
  header.setUint32(12, 0x666d7420, Endian.little); // fmt
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, 1, Endian.little); // mono
  header.setUint32(24, 16000, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  header.setUint32(36, 0x64617461, Endian.little); // data
  header.setUint32(40, raw.length, Endian.little);
  wav.setRange(44, wav.length, raw);
  return wav;
}
