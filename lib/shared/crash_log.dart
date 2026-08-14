import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bounded in-memory crash log plus access to the native crash file.
///
/// Entries never contain API keys, audio payloads, or transcripts: the app
/// only records exception messages, which are exported by the user through
/// the diagnostics dialog.
class CrashLog {
  CrashLog._();

  static final CrashLog instance = CrashLog._();

  static const int _maxEntries = 12;

  final List<String> _entries = <String>[];
  final MethodChannel _channel = MethodChannel(
    'app.realtimetranslation/crash_log',
  );

  List<String> get entries => List<String>.unmodifiable(_entries);

  void record(String entry) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    _entries.add('[$now] $entry');
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
  }

  void installFlutterHooks() {
    FlutterError.onError = (FlutterErrorDetails details) {
      record(details.exceptionAsString().split('\n').take(6).join('\n'));
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      record('$error\n${stack.toString().split('\n').take(6).join('\n')}');
      return true;
    };
  }

  Future<String> readNativeLog() async {
    try {
      final String? log = await _channel
          .invokeMethod<String>('read')
          .timeout(const Duration(seconds: 2));
      return log ?? '';
    } catch (_) {
      return '';
    }
  }
}
