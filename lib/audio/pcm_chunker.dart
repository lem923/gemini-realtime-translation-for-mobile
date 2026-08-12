import 'dart:typed_data';

class PcmChunker {
  PcmChunker({required this.chunkSizeBytes})
    : assert(chunkSizeBytes > 0, 'chunkSizeBytes must be positive');

  final int chunkSizeBytes;
  Uint8List _pending = Uint8List(0);

  int get pendingBytes => _pending.length;

  List<Uint8List> add(Uint8List bytes) {
    if (bytes.isEmpty) {
      return const <Uint8List>[];
    }
    final Uint8List combined = Uint8List(_pending.length + bytes.length)
      ..setRange(0, _pending.length, _pending)
      ..setRange(_pending.length, _pending.length + bytes.length, bytes);
    final List<Uint8List> chunks = <Uint8List>[];
    int offset = 0;
    while (offset + chunkSizeBytes <= combined.length) {
      chunks.add(
        Uint8List.fromList(combined.sublist(offset, offset + chunkSizeBytes)),
      );
      offset += chunkSizeBytes;
    }
    _pending = Uint8List.fromList(combined.sublist(offset));
    return chunks;
  }

  void reset() {
    _pending = Uint8List(0);
  }
}
