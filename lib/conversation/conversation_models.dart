import 'package:flutter/foundation.dart';

import '../shared/translation_language.dart';

enum SpeakerSide { a, b }

enum ConversationPhase {
  needsKey,
  idle,
  connecting,
  listening,
  reconnecting,
  permissionDenied,
  failed,
}

@immutable
class ConversationTurn {
  const ConversationTurn({
    required this.id,
    required this.speaker,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.sourceText,
    required this.translatedText,
    required this.createdAt,
  });

  final int id;
  final SpeakerSide speaker;
  final TranslationLanguage sourceLanguage;
  final TranslationLanguage targetLanguage;
  final String sourceText;
  final String translatedText;
  final DateTime createdAt;
}

class TranscriptAccumulator {
  String _value = '';

  String get value => _value.trim();

  bool get isEmpty => value.isEmpty;

  void add(String next) {
    final String incoming = next.trim();
    if (incoming.isEmpty) {
      return;
    }
    if (incoming.startsWith(_value.trim()) &&
        incoming.length >= _value.length) {
      _value = incoming;
      return;
    }
    if (_value.isEmpty) {
      _value = incoming;
      return;
    }
    final bool needsSpace =
        !RegExp(r'\s$').hasMatch(_value) &&
        !RegExp(r'^[,.;:!?，。！？；：]').hasMatch(incoming);
    _value = '$_value${needsSpace ? ' ' : ''}$incoming';
  }

  void clear() {
    _value = '';
  }
}
