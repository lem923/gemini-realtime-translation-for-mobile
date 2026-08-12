import 'dart:async';

import 'package:flutter/services.dart';

abstract interface class MicrophonePermissionGateway {
  Stream<bool> get changes;
  Future<bool?> currentStatus();
  Future<void> openAppSettings();
}

class DisabledMicrophonePermissionGateway
    implements MicrophonePermissionGateway {
  const DisabledMicrophonePermissionGateway();

  @override
  Stream<bool> get changes => const Stream<bool>.empty();

  @override
  Future<bool?> currentStatus() async => null;

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
  Stream<bool> get changes => _events
      .receiveBroadcastStream()
      .where((Object? value) => value is bool)
      .cast<bool>();

  @override
  Future<bool?> currentStatus() => _methods.invokeMethod<bool>('isGranted');

  @override
  Future<void> openAppSettings() =>
      _methods.invokeMethod<void>('openAppSettings');
}
