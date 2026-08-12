import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_constants.dart';

@immutable
class PcmPlaybackMetrics {
  const PcmPlaybackMetrics({
    required this.queuedBytes,
    required this.maxQueuedBytes,
    required this.droppedChunks,
  });

  const PcmPlaybackMetrics.empty()
    : queuedBytes = 0,
      maxQueuedBytes = 0,
      droppedChunks = 0;

  factory PcmPlaybackMetrics.fromChannelMap(Map<Object?, Object?>? value) {
    int readInt(String key) {
      final Object? raw = value?[key];
      return raw is int && raw >= 0 ? raw : 0;
    }

    return PcmPlaybackMetrics(
      queuedBytes: readInt('queuedBytes'),
      maxQueuedBytes: readInt('maxQueuedBytes'),
      droppedChunks: readInt('droppedChunks'),
    );
  }

  final int queuedBytes;
  final int maxQueuedBytes;
  final int droppedChunks;

  int get queuedMilliseconds =>
      queuedBytes *
      Duration.millisecondsPerSecond ~/
      (outputSampleRateHz * bytesPerSample * channelCount);

  int get maximumQueueMilliseconds =>
      maxQueuedBytes *
      Duration.millisecondsPerSecond ~/
      (outputSampleRateHz * bytesPerSample * channelCount);
}

abstract interface class PcmPlaybackGateway {
  Future<void> configure();
  Future<void> enqueue(Uint8List pcm);
  Future<void> flush();
  Future<PcmPlaybackMetrics> metrics();
  Future<void> dispose();
}

class PlatformPcmPlaybackGateway implements PcmPlaybackGateway {
  static const MethodChannel _channel = MethodChannel(
    'app.realtimetranslation/audio',
  );

  @override
  Future<void> configure() =>
      _channel.invokeMethod<void>('configure', <String, Object>{
        'sampleRate': outputSampleRateHz,
        'channels': channelCount,
      });

  @override
  Future<void> enqueue(Uint8List pcm) =>
      _channel.invokeMethod<void>('enqueue', pcm);

  @override
  Future<void> flush() => _channel.invokeMethod<void>('flush');

  @override
  Future<PcmPlaybackMetrics> metrics() async {
    final Map<Object?, Object?>? value = await _channel
        .invokeMapMethod<Object?, Object?>('metrics');
    return PcmPlaybackMetrics.fromChannelMap(value);
  }

  @override
  Future<void> dispose() => _channel.invokeMethod<void>('dispose');
}
