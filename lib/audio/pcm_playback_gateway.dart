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

class PcmPlaybackRouteChanged extends PcmPlaybackEvent {
  const PcmPlaybackRouteChanged(this.route);

  final AudioOutputRoute route;
}

const int sharedPhoneEchoGuardMicros = 300000;
const int isolatedRouteEchoGuardMicros = 80000;

int echoGuardMicrosForRoute(AudioOutputRoute route) => switch (route) {
  AudioOutputRoute.wired ||
  AudioOutputRoute.bluetooth ||
  AudioOutputRoute.usb ||
  AudioOutputRoute.hearingAid ||
  AudioOutputRoute.hdmi => isolatedRouteEchoGuardMicros,
  AudioOutputRoute.unknown ||
  AudioOutputRoute.speaker ||
  AudioOutputRoute.earpiece => sharedPhoneEchoGuardMicros,
};

@visibleForTesting
PcmPlaybackEvent? parsePcmPlaybackEvent(Object? value) {
  if (value == 'interrupted') {
    return const PcmPlaybackInterrupted();
  }
  if (value case <Object?, Object?>{
    'type': 'routeChanged',
    'outputRoute': final String routeName,
  }) {
    final AudioOutputRoute route = AudioOutputRoute.values.firstWhere(
      (AudioOutputRoute candidate) => candidate.name == routeName,
      orElse: () => AudioOutputRoute.unknown,
    );
    return PcmPlaybackRouteChanged(route);
  }
  return null;
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
      .map(parsePcmPlaybackEvent)
      .where((PcmPlaybackEvent? event) => event != null)
      .cast<PcmPlaybackEvent>();

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
