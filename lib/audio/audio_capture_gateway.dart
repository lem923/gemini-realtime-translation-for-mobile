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

class RecordAudioCaptureGateway implements AudioCaptureGateway {
  RecordAudioCaptureGateway({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  StreamSubscription<Uint8List>? _rawSubscription;
  StreamController<Uint8List>? _output;
  PcmChunker _chunker = PcmChunker(chunkSizeBytes: inputChunkBytes);

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start() async {
    await stop();
    _chunker = PcmChunker(chunkSizeBytes: inputChunkBytes);
    final StreamController<Uint8List> output = StreamController<Uint8List>();
    _output = output;
    final Stream<Uint8List> raw = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: inputSampleRateHz,
        numChannels: channelCount,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
        streamBufferSize: inputChunkBytes,
      ),
    );
    _rawSubscription = raw.listen(
      (Uint8List bytes) {
        for (final Uint8List chunk in _chunker.add(bytes)) {
          output.add(chunk);
        }
      },
      onError: output.addError,
      onDone: output.close,
      cancelOnError: false,
    );
    return output.stream;
  }

  @override
  Future<void> stop() async {
    await _rawSubscription?.cancel();
    _rawSubscription = null;
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
    final StreamController<Uint8List>? output = _output;
    _output = null;
    if (output != null && !output.isClosed) {
      await output.close();
    }
    _chunker.reset();
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _recorder.dispose();
  }
}
