import 'package:flutter/services.dart';

import 'audio_constants.dart';

abstract interface class PcmPlaybackGateway {
  Future<void> configure();
  Future<void> enqueue(Uint8List pcm);
  Future<void> flush();
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
  Future<void> dispose() => _channel.invokeMethod<void>('dispose');
}
