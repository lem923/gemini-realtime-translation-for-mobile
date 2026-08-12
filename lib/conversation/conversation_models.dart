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
  TranscriptAccumulator({this.maxCharacters = 8000})
    : assert(maxCharacters > 0, 'maxCharacters must be positive');

  final int maxCharacters;
  String _value = '';
  bool _truncated = false;

  String get value => _value.trim();

  bool get isEmpty => value.isEmpty;

  void add(String next) {
    final String incoming = next.trim();
    if (incoming.isEmpty) {
      return;
    }
    final String current = _value.trim();
    if ((incoming.startsWith(current) ||
            (_truncated && incoming.contains(current))) &&
        incoming.length >= current.length) {
      _value = incoming;
      _enforceLimit();
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
    _enforceLimit();
  }

  void _enforceLimit() {
    if (_value.length <= maxCharacters) {
      return;
    }
    int start = _value.length - maxCharacters;
    if (start < _value.length && _isLowSurrogate(_value.codeUnitAt(start))) {
      start += 1;
    }
    _value = _value.substring(start).trimLeft();
    _truncated = true;
  }

  static bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  void clear() {
    _value = '';
    _truncated = false;
  }
}
