import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_translation/audio/pcm_chunker.dart';

void main() {
  test('emits fixed-size chunks and retains only the remainder', () {
    final PcmChunker chunker = PcmChunker(chunkSizeBytes: 4);

    expect(chunker.add(Uint8List.fromList(<int>[1, 2, 3])), isEmpty);
    final List<Uint8List> first = chunker.add(
      Uint8List.fromList(<int>[4, 5, 6, 7]),
    );
    expect(first, hasLength(1));
    expect(first.single, orderedEquals(<int>[1, 2, 3, 4]));
    expect(chunker.pendingBytes, 3);

    final List<Uint8List> second = chunker.add(
      Uint8List.fromList(<int>[8, 9, 10, 11, 12]),
    );
    expect(second, hasLength(2));
    expect(second.first, orderedEquals(<int>[5, 6, 7, 8]));
    expect(second.last, orderedEquals(<int>[9, 10, 11, 12]));
    expect(chunker.pendingBytes, 0);
  });
}
