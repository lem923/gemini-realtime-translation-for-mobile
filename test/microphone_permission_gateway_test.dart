import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_translation/permissions/microphone_permission_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('decodes only supported microphone permission wire values', () {
    expect(
      microphonePermissionStatusFromWire('notDetermined'),
      MicrophonePermissionStatus.notDetermined,
    );
    expect(
      microphonePermissionStatusFromWire('granted'),
      MicrophonePermissionStatus.granted,
    );
    expect(
      microphonePermissionStatusFromWire('denied'),
      MicrophonePermissionStatus.denied,
    );
    expect(microphonePermissionStatusFromWire(false), isNull);
    expect(microphonePermissionStatusFromWire('unexpected'), isNull);
  });

  test('reads typed status from the platform boundary', () async {
    const MethodChannel channel = MethodChannel(
      'app.realtimetranslation/permissions',
    );
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return call.method == 'status' ? 'denied' : null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    const PlatformMicrophonePermissionGateway gateway =
        PlatformMicrophonePermissionGateway();
    expect(await gateway.currentStatus(), MicrophonePermissionStatus.denied);
    await gateway.recordRequestResult(granted: false);
    expect(calls, hasLength(2));
    expect(calls.first.method, 'status');
    expect(calls.last.method, 'recordRequestResult');
    expect(calls.last.arguments, <String, bool>{'granted': false});
  });
}
