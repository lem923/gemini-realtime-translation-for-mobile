import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_translation/conversation/conversation_models.dart';

void main() {
  test('accepts accumulated and delta transcript forms', () {
    final TranscriptAccumulator transcript = TranscriptAccumulator();
    transcript.add('Hello');
    transcript.add('Hello world');
    transcript.add('again');

    expect(transcript.value, 'Hello world again');
    transcript.clear();
    expect(transcript.isEmpty, isTrue);
  });

  test('does not insert spaces before punctuation', () {
    final TranscriptAccumulator transcript = TranscriptAccumulator();
    transcript.add('你好');
    transcript.add('！');
    expect(transcript.value, '你好！');
  });

  test('bounds long transcripts and accepts cumulative updates after trim', () {
    final TranscriptAccumulator transcript = TranscriptAccumulator(
      maxCharacters: 8,
    );
    transcript.add('0123456789');
    expect(transcript.value, '23456789');

    transcript.add('0123456789AB');
    expect(transcript.value, '456789AB');
    expect(transcript.value.length, 8);
  });

  test('does not split a surrogate pair while trimming', () {
    final TranscriptAccumulator transcript = TranscriptAccumulator(
      maxCharacters: 4,
    );
    transcript.add('ab😀cd');

    expect(transcript.value, '😀cd');
    expect(transcript.value.runes, <int>[0x1f600, 0x63, 0x64]);
  });
}
