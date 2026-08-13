import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_translation/audio/pcm_playback_gateway.dart';

void main() {
  test('decodes native queue metrics and converts bytes to duration', () {
    final PcmPlaybackMetrics metrics =
        PcmPlaybackMetrics.fromChannelMap(<Object?, Object?>{
          'queuedBytes': 4800,
          'maxQueuedBytes': 72000,
          'droppedChunks': 3,
          'outputRoute': 'bluetooth',
          'audioFocusGranted': true,
        });

    expect(metrics.queuedMilliseconds, 100);
    expect(metrics.maximumQueueMilliseconds, 1500);
    expect(metrics.droppedChunks, 3);
    expect(metrics.outputRoute, AudioOutputRoute.bluetooth);
    expect(metrics.audioFocusGranted, isTrue);
  });

  test('treats missing, negative, or malformed native metrics as zero', () {
    final PcmPlaybackMetrics metrics = PcmPlaybackMetrics.fromChannelMap(
      <Object?, Object?>{'queuedBytes': -1, 'maxQueuedBytes': 'invalid'},
    );

    expect(metrics.queuedBytes, 0);
    expect(metrics.maxQueuedBytes, 0);
    expect(metrics.droppedChunks, 0);
    expect(metrics.outputRoute, AudioOutputRoute.unknown);
    expect(metrics.audioFocusGranted, isFalse);
  });

  test('decodes interruption, route, and typed failure playback events', () {
    expect(parsePcmPlaybackEvent('interrupted'), isA<PcmPlaybackInterrupted>());

    final PcmPlaybackEvent? routeEvent = parsePcmPlaybackEvent(
      <Object?, Object?>{'type': 'routeChanged', 'outputRoute': 'bluetooth'},
    );
    expect(routeEvent, isA<PcmPlaybackRouteChanged>());
    expect(
      (routeEvent! as PcmPlaybackRouteChanged).route,
      AudioOutputRoute.bluetooth,
    );
    final PcmPlaybackEvent? failureEvent =
        parsePcmPlaybackEvent(<Object?, Object?>{
          'type': 'playbackFailed',
          'reason': 'writeError',
          'platformCode': -6,
          'clientGeneration': 7,
        });
    expect(failureEvent, isA<PcmPlaybackFailed>());
    final PcmPlaybackFailed failure = failureEvent! as PcmPlaybackFailed;
    expect(failure.reason, 'writeError');
    expect(failure.platformCode, -6);
    expect(failure.clientGeneration, 7);
    expect(
      parsePcmPlaybackEvent(<Object?, Object?>{
        'type': 'playbackFailed',
        'reason': 'writeException',
        'platformCode': 'invalid',
      }),
      isA<PcmPlaybackFailed>(),
    );
    expect(parsePcmPlaybackEvent('unexpected'), isNull);
  });

  test('uses a conservative echo tail only for shared-phone routes', () {
    for (final AudioOutputRoute route in <AudioOutputRoute>[
      AudioOutputRoute.unknown,
      AudioOutputRoute.speaker,
      AudioOutputRoute.earpiece,
    ]) {
      expect(echoGuardMicrosForRoute(route), sharedPhoneEchoGuardMicros);
    }
    for (final AudioOutputRoute route in <AudioOutputRoute>[
      AudioOutputRoute.wired,
      AudioOutputRoute.bluetooth,
      AudioOutputRoute.usb,
      AudioOutputRoute.hearingAid,
      AudioOutputRoute.hdmi,
    ]) {
      expect(echoGuardMicrosForRoute(route), isolatedRouteEchoGuardMicros);
    }
  });
}
