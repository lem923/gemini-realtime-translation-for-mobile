import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_translation/audio/audio_capture_gateway.dart';
import 'package:realtime_translation/audio/audio_constants.dart';
import 'package:record/record.dart';

void main() {
  test('live capture uses the Gemini PCM wire format', () {
    expect(liveTranslationRecordConfig.encoder, AudioEncoder.pcm16bits);
    expect(liveTranslationRecordConfig.sampleRate, inputSampleRateHz);
    expect(liveTranslationRecordConfig.numChannels, channelCount);
    expect(liveTranslationRecordConfig.streamBufferSize, inputChunkBytes);
  });

  test('Android capture is configured for one communication route owner', () {
    final AndroidRecordConfig android =
        liveTranslationRecordConfig.androidConfig;

    expect(android.audioSource, AndroidAudioSource.voiceCommunication);
    expect(android.manageBluetooth, isFalse);
    expect(android.speakerphone, isFalse);
    expect(android.audioManagerMode, AudioManagerMode.modeNormal);
  });

  test('capture requests speech preprocessing without duplicate focus', () {
    expect(liveTranslationRecordConfig.autoGain, isTrue);
    expect(liveTranslationRecordConfig.echoCancel, isTrue);
    expect(liveTranslationRecordConfig.noiseSuppress, isTrue);
    expect(
      liveTranslationRecordConfig.audioInterruption,
      AudioInterruptionMode.none,
    );
  });

  test(
    'capture start waits for and preserves the first complete PCM chunk',
    () async {
      final _FakeRecorderBackend recorder = _FakeRecorderBackend();
      final RecordAudioCaptureGateway gateway = RecordAudioCaptureGateway(
        recorder: recorder,
        startupTimeout: const Duration(seconds: 1),
      );

      final Future<Stream<Uint8List>> starting = gateway.start();
      bool completed = false;
      unawaited(starting.then((_) => completed = true));
      await Future<void>.delayed(Duration.zero);
      expect(recorder.lastConfig, liveTranslationRecordConfig);
      expect(completed, isFalse);

      final Uint8List chunk = Uint8List(inputChunkBytes);
      recorder.audio.add(chunk);
      final Stream<Uint8List> stream = await starting;

      expect(await stream.first, chunk);
      await gateway.dispose();
    },
  );

  test(
    'recorder initialization error fails startup and releases capture',
    () async {
      final _FakeRecorderBackend recorder = _FakeRecorderBackend();
      final RecordAudioCaptureGateway gateway = RecordAudioCaptureGateway(
        recorder: recorder,
        startupTimeout: const Duration(seconds: 1),
      );

      final Future<Stream<Uint8List>> starting = gateway.start();
      await Future<void>.delayed(Duration.zero);
      recorder.states.addError(StateError('native recorder failed'));

      await expectLater(starting, throwsA(isA<AudioCaptureStartupException>()));
      expect(recorder.stopCount, 1);
      await gateway.dispose();
    },
  );

  test('silent recorder startup times out and releases capture', () async {
    final _FakeRecorderBackend recorder = _FakeRecorderBackend();
    final RecordAudioCaptureGateway gateway = RecordAudioCaptureGateway(
      recorder: recorder,
      startupTimeout: const Duration(milliseconds: 20),
    );

    await expectLater(
      gateway.start(),
      throwsA(isA<AudioCaptureStartupException>()),
    );
    expect(recorder.stopCount, 1);
    await gateway.dispose();
  });
}

class _FakeRecorderBackend implements AudioRecorderBackend {
  final StreamController<Uint8List> audio =
      StreamController<Uint8List>.broadcast();
  final StreamController<RecordState> states =
      StreamController<RecordState>.broadcast();

  RecordConfig? lastConfig;
  bool recording = false;
  int stopCount = 0;

  @override
  Future<void> dispose() async {
    await audio.close();
    await states.close();
  }

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> isRecording() async => recording;

  @override
  Stream<RecordState> onStateChanged() => states.stream;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    lastConfig = config;
    recording = true;
    return audio.stream;
  }

  @override
  Future<void> stop() async {
    recording = false;
    stopCount += 1;
  }
}
