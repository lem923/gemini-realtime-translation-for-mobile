import 'dart:async';

import 'package:flutter/services.dart';

enum MicrophonePermissionStatus { notDetermined, granted, denied }

MicrophonePermissionStatus? microphonePermissionStatusFromWire(Object? value) {
  return switch (value) {
    'notDetermined' => MicrophonePermissionStatus.notDetermined,
    'granted' => MicrophonePermissionStatus.granted,
    'denied' => MicrophonePermissionStatus.denied,
    _ => null,
  };
}

abstract interface class MicrophonePermissionGateway {
  Stream<MicrophonePermissionStatus> get changes;
  Future<MicrophonePermissionStatus?> currentStatus();
  Future<void> recordRequestResult({required bool granted});
  Future<void> openAppSettings();
}

class DisabledMicrophonePermissionGateway
    implements MicrophonePermissionGateway {
  const DisabledMicrophonePermissionGateway();

  @override
  Stream<MicrophonePermissionStatus> get changes =>
      const Stream<MicrophonePermissionStatus>.empty();

  @override
  Future<MicrophonePermissionStatus?> currentStatus() async => null;

  @override
  Future<void> recordRequestResult({required bool granted}) async {}

  @override
  Future<void> openAppSettings() async {}
}

class PlatformMicrophonePermissionGateway
    implements MicrophonePermissionGateway {
  const PlatformMicrophonePermissionGateway();

  static const EventChannel _events = EventChannel(
    'app.realtimetranslation/permission_events',
  );
  static const MethodChannel _methods = MethodChannel(
    'app.realtimetranslation/permissions',
  );

  @override
  Stream<MicrophonePermissionStatus> get changes => _events
      .receiveBroadcastStream()
      .map(microphonePermissionStatusFromWire)
      .where((MicrophonePermissionStatus? status) => status != null)
      .cast<MicrophonePermissionStatus>();

  @override
  Future<MicrophonePermissionStatus?> currentStatus() async {
    final Object? value = await _methods.invokeMethod<Object?>('status');
    return microphonePermissionStatusFromWire(value);
  }

  @override
  Future<void> recordRequestResult({required bool granted}) =>
      _methods.invokeMethod<void>('recordRequestResult', <String, bool>{
        'granted': granted,
      });

  @override
  Future<void> openAppSettings() =>
      _methods.invokeMethod<void>('openAppSettings');
}
