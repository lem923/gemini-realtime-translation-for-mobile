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
}
