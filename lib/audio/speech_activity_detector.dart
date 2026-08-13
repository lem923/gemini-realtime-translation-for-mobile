import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_constants.dart';

enum SpeechGateDecision {
  /// Forward this chunk to the Live transport.
  forward,

  /// Hold this chunk locally; nothing is sent for it.
  hold,

  /// Hold this chunk and finalize the current utterance.
  finalize,
}

/// Energy-based speech gate for the microphone stream.
///
/// The detector tracks a noise floor and uses two thresholds with hysteresis:
/// entering speech requires energy above the floor by [enterSpeechRatio],
/// while an utterance only ends below the floor by [exitSilenceRatio]. Held
/// chunks adapt the floor in both directions, clamped at
/// [absoluteMinimumEnergy]. Holding silence and ambient noise prevents the
/// server from translating it continuously, so playback stays bounded and the
/// next utterance can start; the session maps [finalize] to the server's
/// `audioStreamEnd` turn boundary.
class SpeechActivityDetector {
  SpeechActivityDetector({
    this.chunkSizeBytes = inputChunkBytes,
    this.speechChunksToStartUtterance = 2,
    this.silenceChunksToEndUtterance = 6,
    this.minimumUtteranceChunks = 3,
    this.noiseFloorLearningRate = 0.1,
    this.enterSpeechRatio = 64.0,
    this.exitSilenceRatio = 8.0,
    this.defaultNoiseFloor = 4096.0,
    this.absoluteMinimumEnergy = 256.0,
  }) : assert(chunkSizeBytes > 0),
       assert(chunkSizeBytes % 2 == 0),
       assert(speechChunksToStartUtterance > 0),
       assert(silenceChunksToEndUtterance > 0),
       assert(minimumUtteranceChunks > 0),
       assert(noiseFloorLearningRate > 0 && noiseFloorLearningRate <= 1),
       assert(enterSpeechRatio > exitSilenceRatio),
       assert(exitSilenceRatio > 1) {
    _noiseFloor = defaultNoiseFloor;
  }

  final int chunkSizeBytes;
  final int speechChunksToStartUtterance;
  final int silenceChunksToEndUtterance;
  final int minimumUtteranceChunks;
  final double noiseFloorLearningRate;
  final double enterSpeechRatio;
  final double exitSilenceRatio;
  final double defaultNoiseFloor;
  final double absoluteMinimumEnergy;

  late double _noiseFloor;
  double _lastEnergy = 0;
  bool _inUtterance = false;
  int _speechStreak = 0;
  int _silenceStreak = 0;
  int _utteranceChunks = 0;

  bool get inUtterance => _inUtterance;
  double get noiseFloor => _noiseFloor;
  double get lastEnergy => _lastEnergy;

  double get enterSpeechThreshold => math.max(
    _noiseFloor * enterSpeechRatio,
    absoluteMinimumEnergy * enterSpeechRatio,
  );

  double get exitSilenceThreshold => math.max(
    _noiseFloor * exitSilenceRatio,
    absoluteMinimumEnergy * exitSilenceRatio,
  );

  SpeechGateDecision add(Uint8List chunk) {
    final double energy = _meanSquareEnergy(chunk);
    _lastEnergy = energy;
    if (_inUtterance) {
      _utteranceChunks += 1;
      if (energy > exitSilenceThreshold) {
        _silenceStreak = 0;
      } else {
        _silenceStreak += 1;
        if (_silenceStreak >= silenceChunksToEndUtterance &&
            _utteranceChunks >= minimumUtteranceChunks) {
          _inUtterance = false;
          _speechStreak = 0;
          _silenceStreak = 0;
          _utteranceChunks = 0;
          return SpeechGateDecision.finalize;
        }
      }
      return SpeechGateDecision.forward;
    }
    if (energy > enterSpeechThreshold) {
      _speechStreak += 1;
      _silenceStreak = 0;
      if (_speechStreak >= speechChunksToStartUtterance) {
        _inUtterance = true;
        _utteranceChunks = 0;
        _speechStreak = 0;
      }
      return SpeechGateDecision.forward;
    }
    _speechStreak = 0;
    _silenceStreak += 1;
    final double target = energy < absoluteMinimumEnergy
        ? absoluteMinimumEnergy
        : energy;
    _noiseFloor =
        _noiseFloor * (1 - noiseFloorLearningRate) +
        target * noiseFloorLearningRate;
    return SpeechGateDecision.hold;
  }

  void reset() {
    _noiseFloor = defaultNoiseFloor;
    _lastEnergy = 0;
    _inUtterance = false;
    _speechStreak = 0;
    _silenceStreak = 0;
    _utteranceChunks = 0;
  }

  static double _meanSquareEnergy(Uint8List chunk) {
    if (chunk.length < 2) {
      return 0;
    }
    double sum = 0;
    for (int i = 0; i + 1 < chunk.length; i += 2) {
      int sample = chunk[i] | (chunk[i + 1] << 8);
      if (sample >= 0x8000) {
        sample -= 0x10000;
      }
      sum += sample * sample;
    }
    final int samples = chunk.length ~/ 2;
    return samples == 0 ? 0 : sum / samples;
  }
}
