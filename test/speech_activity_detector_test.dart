import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_translation/audio/audio_constants.dart';
import 'package:realtime_translation/audio/speech_activity_detector.dart';

Uint8List toneChunk({double amplitude = 20000, double rate = 0.25}) {
  final Uint8List chunk = Uint8List(inputChunkBytes);
  for (int i = 0; i < chunk.length; i += 2) {
    final double phase = (i ~/ 2) * 2 * math.pi * rate;
    final int sample = (amplitude * math.sin(phase)).round();
    chunk[i] = sample & 0xff;
    chunk[i + 1] = (sample >> 8) & 0xff;
  }
  return chunk;
}

Uint8List noiseChunk({double amplitude = 30}) =>
    toneChunk(amplitude: amplitude, rate: 0.7);

void main() {
  test('holds silence and adapts the noise floor from ambient noise', () {
    final SpeechActivityDetector detector = SpeechActivityDetector();
    expect(detector.add(Uint8List(inputChunkBytes)), SpeechGateDecision.hold);
    for (int i = 0; i < 20; i += 1) {
      expect(detector.add(noiseChunk()), SpeechGateDecision.hold);
    }
    expect(detector.inUtterance, isFalse);
    expect(detector.noiseFloor, lessThan(detector.defaultNoiseFloor));
    expect(detector.enterSpeechThreshold, greaterThan(detector.noiseFloor));
  });

  test('forwards speech and finalizes after a 1.0 s silence tail', () {
    final SpeechActivityDetector detector = SpeechActivityDetector();
    expect(detector.add(toneChunk()), SpeechGateDecision.forward);
    expect(detector.inUtterance, isFalse);
    expect(detector.add(toneChunk()), SpeechGateDecision.forward);
    expect(detector.inUtterance, isTrue);
    for (int i = 0; i < 9; i += 1) {
      expect(
        detector.add(Uint8List(inputChunkBytes)),
        SpeechGateDecision.forward,
      );
      expect(detector.inUtterance, isTrue);
    }
    expect(
      detector.add(Uint8List(inputChunkBytes)),
      SpeechGateDecision.finalize,
    );
    expect(detector.inUtterance, isFalse);
    expect(detector.add(Uint8List(inputChunkBytes)), SpeechGateDecision.hold);
  });

  test('does not finalize a burst shorter than the minimum utterance', () {
    final SpeechActivityDetector detector = SpeechActivityDetector();
    detector.add(toneChunk());
    detector.add(toneChunk());
    expect(detector.inUtterance, isTrue);
    for (int i = 0; i < 10; i += 1) {
      final SpeechGateDecision decision = detector.add(
        Uint8List(inputChunkBytes),
      );
      if (i < 9) {
        expect(decision, SpeechGateDecision.forward);
      } else {
        expect(decision, SpeechGateDecision.finalize);
      }
    }
    expect(detector.inUtterance, isFalse);
  });

  test('short pauses inside speech do not end the utterance', () {
    final SpeechActivityDetector detector = SpeechActivityDetector();
    detector.add(toneChunk());
    detector.add(toneChunk());
    expect(detector.inUtterance, isTrue);
    detector.add(Uint8List(inputChunkBytes));
    detector.add(Uint8List(inputChunkBytes));
    expect(detector.inUtterance, isTrue);
    expect(detector.add(toneChunk()), SpeechGateDecision.forward);
    expect(detector.inUtterance, isTrue);
  });

  test('reset restores the initial floor and utterance state', () {
    final SpeechActivityDetector detector = SpeechActivityDetector();
    detector.add(noiseChunk());
    detector.add(toneChunk());
    detector.add(toneChunk());
    detector.reset();
    expect(detector.inUtterance, isFalse);
    expect(detector.noiseFloor, detector.defaultNoiseFloor);
    expect(detector.add(toneChunk()), SpeechGateDecision.forward);
  });
}
