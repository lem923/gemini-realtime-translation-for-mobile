import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_constants.dart';

enum AudioOutputRoute {
  unknown,
  speaker,
  earpiece,
  wired,
  bluetooth,
  usb,
  hearingAid,
  hdmi,
}

sealed class PcmPlaybackEvent {
  const PcmPlaybackEvent();
}

class PcmPlaybackInterrupted extends PcmPlaybackEvent {
  const PcmPlaybackInterrupted();
}

@immutable
class PcmPlaybackMetrics {
  const PcmPlaybackMetrics({
    required this.queuedBytes,
    required this.maxQueuedBytes,
    required this.droppedChunks,
    required this.outputRoute,
    required this.audioFocusGranted,
  });

  const PcmPlaybackMetrics.empty()
    : queuedBytes = 0,
      maxQueuedBytes = 0,
      droppedChunks = 0,
      outputRoute = AudioOutputRoute.unknown,
      audioFocusGranted = false;

  factory PcmPlaybackMetrics.fromChannelMap(Map<Object?, Object?>? value) {
    int readInt(String key) {
      final Object? raw = value?[key];
      return raw is int && raw >= 0 ? raw : 0;
    }

    return PcmPlaybackMetrics(
      queuedBytes: readInt('queuedBytes'),
      maxQueuedBytes: readInt('maxQueuedBytes'),
      droppedChunks: readInt('droppedChunks'),
      outputRoute: AudioOutputRoute.values.firstWhere(
        (AudioOutputRoute route) => route.name == value?['outputRoute'],
        orElse: () => AudioOutputRoute.unknown,
      ),
      audioFocusGranted: value?['audioFocusGranted'] == true,
    );
  }

  final int queuedBytes;
  final int maxQueuedBytes;
  final int droppedChunks;
  final AudioOutputRoute outputRoute;
  final bool audioFocusGranted;

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
  Stream<PcmPlaybackEvent> get events;
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
  static const EventChannel _eventChannel = EventChannel(
    'app.realtimetranslation/audio_events',
  );

  @override
  Stream<PcmPlaybackEvent> get events => _eventChannel
      .receiveBroadcastStream()
      .where((Object? event) => event == 'interrupted')
      .map((Object? _) => const PcmPlaybackInterrupted());

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
