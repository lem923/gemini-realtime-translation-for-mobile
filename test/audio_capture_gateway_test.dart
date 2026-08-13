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

  test(
    'stop cancels a pending startup without waiting for its timeout',
    () async {
      final _FakeRecorderBackend recorder = _FakeRecorderBackend();
      final RecordAudioCaptureGateway gateway = RecordAudioCaptureGateway(
        recorder: recorder,
        startupTimeout: const Duration(seconds: 1),
      );

      final Future<Stream<Uint8List>> starting = gateway.start();
      final Future<void> failure = expectLater(
        starting.timeout(const Duration(milliseconds: 100)),
        throwsA(isA<AudioCaptureStartupException>()),
      );
      await Future<void>.delayed(Duration.zero);
      await gateway.stop();

      await failure;
      expect(recorder.stopCount, 1);
      await gateway.dispose();
    },
  );

  test('cancelled startup cannot stop the next healthy capture', () async {
    final _FakeRecorderBackend recorder = _FakeRecorderBackend();
    final RecordAudioCaptureGateway gateway = RecordAudioCaptureGateway(
      recorder: recorder,
      startupTimeout: const Duration(milliseconds: 30),
    );

    final Future<Stream<Uint8List>> firstStart = gateway.start();
    final Future<void> firstFailure = expectLater(
      firstStart,
      throwsA(isA<AudioCaptureStartupException>()),
    );
    await Future<void>.delayed(Duration.zero);
    await gateway.stop();
    await firstFailure;

    final Future<Stream<Uint8List>> secondStart = gateway.start();
    await Future<void>.delayed(Duration.zero);
    final Uint8List chunk = Uint8List(inputChunkBytes);
    recorder.audio.add(chunk);
    final Stream<Uint8List> secondStream = await secondStart;
    expect(await secondStream.first, chunk);

    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(recorder.recording, isTrue);
    expect(recorder.stopCount, 1);
    await gateway.dispose();
  });

  test(
    'state subscription cancellation failure cannot abort capture cleanup',
    () async {
      final _FakeRecorderBackend recorder = _FakeRecorderBackend(
        failStateCancellation: true,
      );
      final RecordAudioCaptureGateway gateway = RecordAudioCaptureGateway(
        recorder: recorder,
        startupTimeout: const Duration(seconds: 1),
      );

      final Future<Stream<Uint8List>> starting = gateway.start();
      await Future<void>.delayed(Duration.zero);
      recorder.audio.add(Uint8List(inputChunkBytes));
      final Stream<Uint8List> stream = await starting;
      final Completer<void> streamClosed = Completer<void>();
      final StreamSubscription<Uint8List> outputSubscription = stream.listen(
        (_) {},
        onDone: streamClosed.complete,
      );

      await gateway.stop();

      await streamClosed.future.timeout(const Duration(seconds: 1));
      expect(recorder.stopCount, 1);
      expect(recorder.recording, isFalse);
      await outputSubscription.cancel();
      await gateway.dispose();
    },
  );

  test('recorder state query failure still attempts native stop', () async {
    final _FakeRecorderBackend recorder = _FakeRecorderBackend();
    final RecordAudioCaptureGateway gateway = RecordAudioCaptureGateway(
      recorder: recorder,
      startupTimeout: const Duration(seconds: 1),
    );

    final Future<Stream<Uint8List>> starting = gateway.start();
    await Future<void>.delayed(Duration.zero);
    recorder.audio.add(Uint8List(inputChunkBytes));
    await starting;
    recorder.failRecordingQuery = true;

    await gateway.stop();

    expect(recorder.stopCount, 1);
    expect(recorder.recording, isFalse);
    await gateway.dispose();
    expect(recorder.disposeCount, 1);
  });

  test(
    'native stop failure retires the recorder and preserves retry',
    () async {
      final _FakeRecorderBackend failedRecorder = _FakeRecorderBackend(
        stopError: StateError('native stop failed'),
      );
      late _FakeRecorderBackend replacementRecorder;
      final RecordAudioCaptureGateway gateway = RecordAudioCaptureGateway(
        recorder: failedRecorder,
        recorderFactory: () {
          replacementRecorder = _FakeRecorderBackend();
          return replacementRecorder;
        },
        startupTimeout: const Duration(seconds: 1),
      );

      final Future<Stream<Uint8List>> firstStart = gateway.start();
      await Future<void>.delayed(Duration.zero);
      failedRecorder.audio.add(Uint8List(inputChunkBytes));
      await firstStart;
      await gateway.stop();

      expect(failedRecorder.stopCount, 1);
      expect(failedRecorder.disposeCount, 1);
      expect(failedRecorder.recording, isFalse);

      final Future<Stream<Uint8List>> retry = gateway.start();
      await Future<void>.delayed(Duration.zero);
      replacementRecorder.audio.add(Uint8List(inputChunkBytes));
      final Stream<Uint8List> retryStream = await retry;
      expect(await retryStream.first, hasLength(inputChunkBytes));
      await gateway.dispose();
      expect(replacementRecorder.stopCount, 1);
      expect(replacementRecorder.disposeCount, 1);
    },
  );
}

class _FakeRecorderBackend implements AudioRecorderBackend {
  _FakeRecorderBackend({this.failStateCancellation = false, this.stopError}) {
    audio = StreamController<Uint8List>.broadcast();
    states = StreamController<RecordState>.broadcast();
  }

  final bool failStateCancellation;
  final Object? stopError;
  late final StreamController<Uint8List> audio;
  late final StreamController<RecordState> states;

  RecordConfig? lastConfig;
  bool recording = false;
  bool failRecordingQuery = false;
  int stopCount = 0;
  int disposeCount = 0;

  @override
  Future<void> dispose() async {
    disposeCount += 1;
    recording = false;
    await audio.close();
    await states.close();
  }

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> isRecording() async {
    if (failRecordingQuery) {
      throw StateError('recording state unavailable');
    }
    return recording;
  }

  @override
  Stream<RecordState> onStateChanged() => failStateCancellation
      ? _CancelFailingStream<RecordState>(states.stream)
      : states.stream;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    lastConfig = config;
    recording = true;
    return audio.stream;
  }

  @override
  Future<void> stop() async {
    stopCount += 1;
    final Object? error = stopError;
    if (error != null) {
      throw error;
    }
    recording = false;
  }
}

class _CancelFailingStream<T> extends Stream<T> {
  const _CancelFailingStream(this._delegate);

  final Stream<T> _delegate;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _CancelFailingSubscription<T>(
      _delegate.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      ),
    );
  }
}

class _CancelFailingSubscription<T> implements StreamSubscription<T> {
  const _CancelFailingSubscription(this._delegate);

  final StreamSubscription<T> _delegate;

  @override
  Future<void> cancel() async {
    await _delegate.cancel();
    throw StateError('state cancel failed');
  }

  @override
  void onData(void Function(T data)? handleData) =>
      _delegate.onData(handleData);

  @override
  void onError(Function? handleError) => _delegate.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _delegate.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _delegate.pause(resumeSignal);

  @override
  void resume() => _delegate.resume();

  @override
  bool get isPaused => _delegate.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _delegate.asFuture<E>(futureValue);
}
