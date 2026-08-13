import 'dart:async';

import 'package:flutter/services.dart';

import 'audio_constants.dart';

enum HeadsetCaptureState { unavailable, available }

abstract interface class HeadsetCaptureGateway {
  Future<HeadsetCaptureState> state();
  Future<Stream<Uint8List>> start();
  Future<void> stop();
  Future<void> dispose();
}

/// Captures the microphone of a connected wired or Bluetooth headset
/// independently of the built-in microphone, for headset-split conversation
/// mode. Fails closed: [start] throws when no headset microphone is present.
/// Every platform call is bounded so a missing or broken platform
/// implementation can never strand cleanup.
class NativeHeadsetCaptureGateway implements HeadsetCaptureGateway {
  static const MethodChannel _channel = MethodChannel(
    'app.realtimetranslation/headset_capture',
  );
  static const EventChannel _eventChannel = EventChannel(
    'app.realtimetranslation/headset_capture_events',
  );

  static const Duration _platformTimeout = Duration(seconds: 2);

  StreamSubscription<Object?>? _subscription;

  @override
  Future<HeadsetCaptureState> state() async {
    final String? name;
    try {
      name = await _channel
          .invokeMethod<String>('state')
          .timeout(_platformTimeout);
    } on PlatformException {
      return HeadsetCaptureState.unavailable;
    } on MissingPluginException {
      return HeadsetCaptureState.unavailable;
    } on TimeoutException {
      return HeadsetCaptureState.unavailable;
    }
    return name == 'available'
        ? HeadsetCaptureState.available
        : HeadsetCaptureState.unavailable;
  }

  @override
  Future<Stream<Uint8List>> start() async {
    await stop();
    try {
      await _channel.invokeMethod<void>('start').timeout(_platformTimeout);
    } on PlatformException catch (_) {
      throw const HeadsetCaptureUnavailableException();
    } on MissingPluginException catch (_) {
      throw const HeadsetCaptureUnavailableException();
    } on TimeoutException catch (_) {
      throw const HeadsetCaptureUnavailableException();
    }
    final Stream<Object?> raw = _eventChannel.receiveBroadcastStream(
      <String, Object?>{'chunkBytes': inputChunkBytes},
    );
    _subscription = raw.listen((_) {}, onError: (Object _, StackTrace _) {});
    return raw.cast<Uint8List>();
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _channel.invokeMethod<void>('stop').timeout(_platformTimeout);
    } on PlatformException {
      // The native side reports and releases its own resources; a stop
      // failure must not strand an otherwise healthy conversation.
    } on MissingPluginException {
      // No platform implementation exists (e.g., widget tests).
    } on TimeoutException {
      // A slow platform is treated as already stopped.
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
  }
}

class HeadsetCaptureUnavailableException implements Exception {
  const HeadsetCaptureUnavailableException();
}
