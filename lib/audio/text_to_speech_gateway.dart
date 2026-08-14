import 'dart:io';

import 'package:flutter/services.dart';

abstract interface class TextToSpeech {
  Future<Uint8List?> synthesize({
    required String text,
    required String languageCode,
  });

  Future<void> dispose();
}

/// Synthesizes text through the platform's system TTS engine and returns the
/// PCM for the playback gateway (24 kHz mono 16-bit), preserving mute, queue,
/// and echo-guard behavior. Fails closed on any platform error.
class TextToSpeechGateway implements TextToSpeech {
  static const MethodChannel _channel = MethodChannel(
    'app.realtimetranslation/tts',
  );

  @override
  @override
  Future<Uint8List?> synthesize({
    required String text,
    required String languageCode,
  }) async {
    final String? path;
    try {
      path = await _channel.invokeMethod<String>('synthesize', <String, Object>{
        'text': text,
        'languageCode': languageCode,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
    if (path == null) {
      return null;
    }
    try {
      final File file = File(path);
      if (!file.existsSync()) {
        return null;
      }
      final Uint8List wav = await file.readAsBytes();
      return _decodeWavToPcm(wav);
    } catch (_) {
      return null;
    }
  }

  @override
  @override
  Future<void> dispose() async {
    try {
      await _channel.invokeMethod<void>('dispose');
    } catch (_) {
      // Best-effort release of the engine.
    }
  }

  /// Reads a standard PCM WAV and resamples to 24 kHz mono 16-bit.
  Uint8List? _decodeWavToPcm(Uint8List wav) {
    if (wav.length < 44) {
      return null;
    }
    int offset = 12;
    int dataOffset = -1;
    int dataLength = 0;
    int sampleRate = 0;
    int channels = 1;
    int bitsPerSample = 16;
    while (offset + 8 <= wav.length) {
      final String chunkId = String.fromCharCodes(
        wav.sublist(offset, offset + 4),
      );
      final int chunkSize = _leUint32(wav, offset + 4);
      if (chunkId == 'fmt ') {
        channels = _leUint16(wav, offset + 10);
        sampleRate = _leUint32(wav, offset + 12);
        bitsPerSample = _leUint16(wav, offset + 22);
      } else if (chunkId == 'data') {
        dataOffset = offset + 8;
        dataLength = chunkSize;
      }
      offset += 8 + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }
    if (dataOffset < 0 || dataLength <= 0 || channels <= 0 || channels > 2) {
      return null;
    }
    if (bitsPerSample != 16) {
      return null;
    }
    final Uint8List pcm = Uint8List.sublistView(
      wav,
      dataOffset,
      dataOffset + dataLength > wav.length
          ? wav.length
          : dataOffset + dataLength,
    );
    Uint8List mono = pcm;
    if (channels == 2) {
      mono = _toMono(pcm);
    }
    if (sampleRate == 24000) {
      return mono;
    }
    if (sampleRate <= 0) {
      return null;
    }
    return _resample(mono, sampleRate, 24000);
  }

  static int _leUint16(Uint8List data, int offset) =>
      (data[offset] | (data[offset + 1] << 8)) & 0xffff;

  static int _leUint32(Uint8List data, int offset) =>
      data[offset] |
      (data[offset + 1] << 8) |
      (data[offset + 2] << 16) |
      (data[offset + 3] << 24);

  static Uint8List _toMono(Uint8List stereo) {
    final Uint8List mono = Uint8List(stereo.length ~/ 2);
    for (int i = 0, j = 0; i + 3 < stereo.length; i += 4, j += 2) {
      final int left = stereo[i] | (stereo[i + 1] << 8);
      final int right = stereo[i + 2] | (stereo[i + 3] << 8);
      final int sum = (left + right) ~/ 2;
      mono[j] = sum & 0xff;
      mono[j + 1] = (sum >> 8) & 0xff;
    }
    return mono;
  }

  static Uint8List _resample(Uint8List input, int fromRate, int toRate) {
    final int inSamples = input.length ~/ 2;
    final int outSamples = (inSamples * toRate / fromRate).floor();
    final Uint8List output = Uint8List(outSamples * 2);
    double position = 0;
    final double step = fromRate / toRate;
    for (int i = 0; i < outSamples; i++) {
      final int index = position.floor();
      final int sampleA = _sampleAt(input, index, inSamples);
      final int sampleB = _sampleAt(input, index + 1, inSamples);
      final double fraction = position - index;
      final int sample = (sampleA + (sampleB - sampleA) * fraction)
          .round()
          .clamp(-32768, 32767);
      output[i * 2] = sample & 0xff;
      output[i * 2 + 1] = (sample >> 8) & 0xff;
      position += step;
    }
    return output;
  }

  static int _sampleAt(Uint8List input, int index, int inSamples) {
    if (index < 0) {
      return 0;
    }
    if (index >= inSamples) {
      return 0;
    }
    int sample = input[index * 2] | (input[index * 2 + 1] << 8);
    if (sample >= 0x8000) {
      sample -= 0x10000;
    }
    return sample;
  }
}
