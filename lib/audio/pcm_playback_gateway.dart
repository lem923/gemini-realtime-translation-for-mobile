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

/// Physical destination for translated audio in headset-split mode.
enum PlaybackTrack { phoneSpeaker, headset }

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

class PcmPlaybackFailed extends PcmPlaybackEvent {
  const PcmPlaybackFailed({
    required this.reason,
    this.platformCode,
    this.clientGeneration,
  });

  final String reason;
  final int? platformCode;
  final int? clientGeneration;
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
  if (value case <Object?, Object?>{
    'type': 'playbackFailed',
    'reason': final String reason,
  }) {
    final Object? rawPlatformCode = value['platformCode'];
    return PcmPlaybackFailed(
      reason: reason,
      platformCode: rawPlatformCode is int ? rawPlatformCode : null,
      clientGeneration: value['clientGeneration'] is int
          ? value['clientGeneration']! as int
          : null,
    );
  }
  return null;
}

@immutable
class PcmPlaybackMetrics {
  const PcmPlaybackMetrics({
    required this.queuedBytes,
    required this.maxQueuedBytes,
    required this.droppedChunks,
    this.pendingPlaybackBytes = 0,
    required this.outputRoute,
    required this.audioFocusGranted,
  });

  const PcmPlaybackMetrics.empty()
    : queuedBytes = 0,
      maxQueuedBytes = 0,
      droppedChunks = 0,
      pendingPlaybackBytes = 0,
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
      pendingPlaybackBytes: readInt('pendingPlaybackBytes'),
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

  /// Queued bytes plus bytes already written to the AudioTrack but not yet
  /// audible; drains to zero when the translated tail has fully played out.
  final int pendingPlaybackBytes;
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
  Future<void> configure({
    required int clientGeneration,
    bool forceSpeakerToPhone = false,
  });
  Future<void> enqueue(Uint8List pcm);
  Future<void> enqueueTrack(PlaybackTrack track, Uint8List pcm);
  Future<void> flush();
  Future<void> flushTrack(PlaybackTrack track);
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
  Future<void> configure({
    required int clientGeneration,
    bool forceSpeakerToPhone = false,
  }) => _channel.invokeMethod<void>('configure', <String, Object>{
    'sampleRate': outputSampleRateHz,
    'channels': channelCount,
    'clientGeneration': clientGeneration,
    'forceSpeakerToPhone': forceSpeakerToPhone,
  });

  @override
  Future<void> enqueue(Uint8List pcm) =>
      _channel.invokeMethod<void>('enqueue', pcm);

  @override
  Future<void> enqueueTrack(PlaybackTrack track, Uint8List pcm) =>
      _channel.invokeMethod<void>('enqueueTrack', <String, Object>{
        'track': track.name,
        'pcm': pcm,
      });

  @override
  Future<void> flush() => _channel.invokeMethod<void>('flush');

  @override
  Future<void> flushTrack(PlaybackTrack track) =>
      _channel.invokeMethod<void>('flushTrack', track.name);

  @override
  Future<PcmPlaybackMetrics> metrics() async {
    final Map<Object?, Object?>? value = await _channel
        .invokeMapMethod<Object?, Object?>('metrics');
    return PcmPlaybackMetrics.fromChannelMap(value);
  }

  @override
  Future<void> dispose() => _channel.invokeMethod<void>('dispose');
}
