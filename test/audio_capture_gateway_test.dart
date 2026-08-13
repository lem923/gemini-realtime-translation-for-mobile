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
}
