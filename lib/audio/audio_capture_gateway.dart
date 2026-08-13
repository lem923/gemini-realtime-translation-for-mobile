import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'audio_constants.dart';
import 'pcm_chunker.dart';

abstract interface class AudioCaptureGateway {
  Future<bool> hasPermission();
  Future<Stream<Uint8List>> start();
  Future<void> stop();
  Future<void> dispose();
}

class AudioCaptureStartupException implements Exception {
  const AudioCaptureStartupException();
}

abstract interface class AudioRecorderBackend {
  Future<bool> hasPermission();
  Stream<RecordState> onStateChanged();
  Future<Stream<Uint8List>> startStream(RecordConfig config);
  Future<bool> isRecording();
  Future<void> stop();
  Future<void> dispose();
}

class PackageAudioRecorderBackend implements AudioRecorderBackend {
  PackageAudioRecorderBackend([AudioRecorder? recorder])
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Stream<RecordState> onStateChanged() => _recorder.onStateChanged();

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) =>
      _recorder.startStream(config);

  @override
  Future<bool> isRecording() => _recorder.isRecording();

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// Capture settings shared by the Android-first implementation and the future
/// iOS adapter. Android routing remains owned by the native playback adapter so
/// capture and translated playback cannot issue competing Bluetooth requests.
const RecordConfig liveTranslationRecordConfig = RecordConfig(
  encoder: AudioEncoder.pcm16bits,
  sampleRate: inputSampleRateHz,
  numChannels: channelCount,
  autoGain: true,
  echoCancel: true,
  noiseSuppress: true,
  streamBufferSize: inputChunkBytes,
  androidConfig: AndroidRecordConfig(
    manageBluetooth: false,
    audioSource: AndroidAudioSource.voiceCommunication,
  ),
  // The native playback adapter owns the single app-level audio-focus request
  // and forwards interruptions to the conversation controller. A second
  // request from `record` would evict our own focus owner.
  audioInterruption: AudioInterruptionMode.none,
);

class RecordAudioCaptureGateway implements AudioCaptureGateway {
  RecordAudioCaptureGateway({
    AudioRecorderBackend? recorder,
    this.startupTimeout = const Duration(seconds: 3),
  }) : _recorder = recorder ?? PackageAudioRecorderBackend();

  final AudioRecorderBackend _recorder;
  final Duration startupTimeout;
  StreamSubscription<RecordState>? _stateSubscription;
  StreamSubscription<Uint8List>? _rawSubscription;
  StreamController<Uint8List>? _output;
  Completer<void>? _startupCompleter;
  int _captureGeneration = 0;
  PcmChunker _chunker = PcmChunker(chunkSizeBytes: inputChunkBytes);

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start() async {
    await stop();
    final int generation = ++_captureGeneration;
    _chunker = PcmChunker(chunkSizeBytes: inputChunkBytes);
    final StreamController<Uint8List> output = StreamController<Uint8List>();
    _output = output;
    final Completer<void> startup = Completer<void>();
    _startupCompleter = startup;
    // Stop can cancel startup while the native start method is still pending.
    // Observe the error immediately while preserving it for the awaited path.
    unawaited(startup.future.catchError((Object _) {}));
    bool captureReady = false;
    bool failureReported = false;

    void reportFailure(Object error, StackTrace stackTrace) {
      if (generation != _captureGeneration) {
        return;
      }
      if (!captureReady) {
        if (!startup.isCompleted) {
          startup.completeError(
            const AudioCaptureStartupException(),
            stackTrace,
          );
        }
        return;
      }
      if (!failureReported && !output.isClosed) {
        failureReported = true;
        output.addError(error, stackTrace);
      }
    }

    _stateSubscription = _recorder.onStateChanged().listen(
      (_) {},
      onError: reportFailure,
      cancelOnError: false,
    );

    try {
      final Stream<Uint8List> raw = await _recorder.startStream(
        liveTranslationRecordConfig,
      );
      if (generation != _captureGeneration) {
        throw const AudioCaptureStartupException();
      }
      _rawSubscription = raw.listen(
        (Uint8List bytes) {
          if (generation != _captureGeneration) {
            return;
          }
          for (final Uint8List chunk in _chunker.add(bytes)) {
            output.add(chunk);
            if (!captureReady) {
              captureReady = true;
              startup.complete();
            }
          }
        },
        onError: reportFailure,
        onDone: () {
          if (generation != _captureGeneration) {
            return;
          }
          if (!captureReady) {
            reportFailure(
              const AudioCaptureStartupException(),
              StackTrace.current,
            );
          } else if (!output.isClosed) {
            unawaited(output.close());
          }
        },
        cancelOnError: false,
      );
      await startup.future.timeout(startupTimeout);
      if (generation != _captureGeneration) {
        throw const AudioCaptureStartupException();
      }
      if (identical(_startupCompleter, startup)) {
        _startupCompleter = null;
      }
      return output.stream;
    } on AudioCaptureStartupException {
      if (generation == _captureGeneration) {
        await stop();
      }
      rethrow;
    } on TimeoutException catch (_, stackTrace) {
      if (generation == _captureGeneration) {
        await stop();
      }
      Error.throwWithStackTrace(
        const AudioCaptureStartupException(),
        stackTrace,
      );
    } catch (error, stackTrace) {
      if (generation == _captureGeneration) {
        await stop();
      }
      Error.throwWithStackTrace(
        const AudioCaptureStartupException(),
        stackTrace,
      );
    }
  }

  @override
  Future<void> stop() async {
    _captureGeneration += 1;
    final Completer<void>? startup = _startupCompleter;
    _startupCompleter = null;
    if (startup != null && !startup.isCompleted) {
      startup.completeError(
        const AudioCaptureStartupException(),
        StackTrace.current,
      );
    }
    try {
      await _stateSubscription?.cancel();
    } catch (_) {
      // A failing callback subscription must not strand the audio stream or
      // native recorder.
    } finally {
      _stateSubscription = null;
    }
    try {
      await _rawSubscription?.cancel();
    } catch (_) {
      // Continue with the authoritative native stop below.
    } finally {
      _rawSubscription = null;
    }
    var shouldStopRecorder = true;
    try {
      shouldStopRecorder = await _recorder.isRecording();
    } catch (_) {
      // If state cannot be queried, fail safe and attempt the idempotent stop.
    }
    if (shouldStopRecorder) {
      try {
        await _recorder.stop();
      } catch (_) {
        // Local stream ownership is still released below. dispose() also
        // invokes the backend's terminal release when the gateway is retired.
      }
    }
    final StreamController<Uint8List>? output = _output;
    _output = null;
    if (output != null && !output.isClosed) {
      try {
        final Future<void> closed = output.close();
        // A single-subscription controller intentionally buffers the first PCM
        // chunk until the caller attaches. Its close Future does not complete if
        // startup failed before a listener existed, so cleanup must not wait in
        // that case.
        if (output.hasListener) {
          await closed;
        }
      } catch (_) {
        // The generation is already invalid, so no callback can publish more
        // audio even if a listener races the close.
      }
    }
    _chunker.reset();
  }

  @override
  Future<void> dispose() async {
    try {
      await stop();
    } finally {
      await _recorder.dispose();
    }
  }
}
