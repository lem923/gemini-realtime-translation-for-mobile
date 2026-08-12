import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:realtime_translation/live_translate/live_event.dart';
import 'package:realtime_translation/live_translate/live_translation_session.dart';

const int _chunkBytes = 3200;
const int _maximumFixtureBytes = 16000 * 2 * 60;

Future<void> main(List<String> arguments) async {
  final String apiKey = Platform.environment['GEMINI_API_KEY']?.trim() ?? '';
  final String manifestPath =
      Platform.environment['LIVE_TEST_DIALOG_MANIFEST']?.trim() ?? '';
  final int? timeoutSeconds = int.tryParse(
    Platform.environment['LIVE_TEST_TURN_TIMEOUT_SECONDS']?.trim() ?? '45',
  );
  final int? switchDelayMilliseconds = int.tryParse(
    Platform.environment['LIVE_TEST_SWITCH_DELAY_MILLISECONDS']?.trim() ??
        '4000',
  );
  if (apiKey.isEmpty ||
      manifestPath.isEmpty ||
      timeoutSeconds == null ||
      switchDelayMilliseconds == null) {
    stderr.writeln(
      'Set GEMINI_API_KEY, LIVE_TEST_DIALOG_MANIFEST, and an integer '
      'LIVE_TEST_TURN_TIMEOUT_SECONDS (default 45). Optionally set an integer '
      'LIVE_TEST_SWITCH_DELAY_MILLISECONDS (default 4000).',
    );
    exitCode = 64;
    return;
  }
  if (timeoutSeconds <= 0 || timeoutSeconds > 120) {
    stderr.writeln('LIVE_TEST_TURN_TIMEOUT_SECONDS must be between 1 and 120.');
    exitCode = 64;
    return;
  }
  if (switchDelayMilliseconds < 0 || switchDelayMilliseconds > 10000) {
    stderr.writeln(
      'LIVE_TEST_SWITCH_DELAY_MILLISECONDS must be between 0 and 10000.',
    );
    exitCode = 64;
    return;
  }

  _DialogProbe? directionA;
  _DialogProbe? directionB;
  var completedTurns = 0;
  var failedTurns = 0;
  try {
    final _DialogManifest manifest = await _DialogManifest.load(
      File(manifestPath),
    );
    directionA = _DialogProbe(
      apiKey: apiKey,
      targetLanguageCode: manifest.languageB,
    );
    directionB = _DialogProbe(
      apiKey: apiKey,
      targetLanguageCode: manifest.languageA,
    );
    await Future.wait<void>(<Future<void>>[
      directionA.connect(),
      directionB.connect(),
    ]);

    final List<int> firstAudioLatencies = <int>[];
    final List<int> firstTranslationLatencies = <int>[];
    var inputTranscriptCharacters = 0;
    var outputTranscriptCharacters = 0;
    var outputAudioBytes = 0;
    var serverTurnCompleteEvents = 0;
    for (var index = 0; index < manifest.turns.length; index += 1) {
      final _DialogTurnSpec turn = manifest.turns[index];
      final _DialogProbe probe = turn.speaker == _Speaker.a
          ? directionA
          : directionB;
      final String sourceLanguage = turn.speaker == _Speaker.a
          ? manifest.languageA
          : manifest.languageB;
      final String targetLanguage = turn.speaker == _Speaker.a
          ? manifest.languageB
          : manifest.languageA;
      final _TurnEvidence evidence = await probe.runTurn(
        turn,
        sourceLanguageCode: sourceLanguage,
        targetLanguageCode: targetLanguage,
        timeout: Duration(seconds: timeoutSeconds),
        switchDelay: Duration(milliseconds: switchDelayMilliseconds),
      );
      completedTurns += 1;
      inputTranscriptCharacters += evidence.inputTranscriptCharacters;
      outputTranscriptCharacters += evidence.outputTranscriptCharacters;
      outputAudioBytes += evidence.outputAudioBytes;
      if (evidence.serverTurnComplete) serverTurnCompleteEvents += 1;
      firstAudioLatencies.add(evidence.firstAudioMilliseconds);
      firstTranslationLatencies.add(evidence.firstTranslationMilliseconds);
      stdout.writeln(
        'dialog_turn index=${index + 1} '
        'scenario=${turn.scenario} '
        'speaker=${turn.speaker.label} '
        'passed=true '
        'input_text_chars=${evidence.inputTranscriptCharacters} '
        'output_text_chars=${evidence.outputTranscriptCharacters} '
        'output_audio_bytes=${evidence.outputAudioBytes} '
        'server_turn_complete=${evidence.serverTurnComplete} '
        'first_translation_ms=${evidence.firstTranslationMilliseconds} '
        'first_audio_ms=${evidence.firstAudioMilliseconds}',
      );
    }

    final int failureEvents =
        directionA.failureEvents + directionB.failureEvents;
    final int reconnectEvents =
        directionA.reconnectEvents + directionB.reconnectEvents;
    final int promptTokens = directionA.promptTokens + directionB.promptTokens;
    final int responseTokens =
        directionA.responseTokens + directionB.responseTokens;
    final int totalTokens = directionA.totalTokens + directionB.totalTokens;
    final bool passed =
        completedTurns == manifest.turns.length &&
        failureEvents == 0 &&
        inputTranscriptCharacters > 0 &&
        outputTranscriptCharacters > 0 &&
        outputAudioBytes > 0;
    stdout.writeln(
      'live_dialog_smoke passed=$passed '
      'turns=${manifest.turns.length} '
      'completed_turns=$completedTurns '
      'failed_turns=$failedTurns '
      'direction_switches=${(manifest.turns.length - 1).clamp(0, 50)} '
      'failure_events=$failureEvents '
      'reconnect_events=$reconnectEvents '
      'input_text_chars=$inputTranscriptCharacters '
      'output_text_chars=$outputTranscriptCharacters '
      'output_audio_bytes=$outputAudioBytes '
      'server_turn_complete_events=$serverTurnCompleteEvents '
      'first_translation_p50_ms=${_percentile(firstTranslationLatencies, 0.50)} '
      'first_translation_p95_ms=${_percentile(firstTranslationLatencies, 0.95)} '
      'first_audio_p50_ms=${_percentile(firstAudioLatencies, 0.50)} '
      'first_audio_p95_ms=${_percentile(firstAudioLatencies, 0.95)} '
      'prompt_tokens=$promptTokens '
      'response_tokens=$responseTokens '
      'total_tokens=$totalTokens',
    );
    if (!passed) exitCode = 1;
  } on Object catch (error) {
    failedTurns += 1;
    stderr.writeln(
      'live_dialog_smoke failed '
      'completed_turns=$completedTurns '
      'failed_turns=$failedTurns '
      'error_type=${error.runtimeType} '
      'error_code=${_safeErrorCode(error)}',
    );
    exitCode = 1;
  } finally {
    await directionA?.close();
    await directionB?.close();
  }
}

String _safeErrorCode(Object error) {
  if (error is TimeoutException) return 'timeout';
  if (error is FormatException) return 'invalid-manifest';
  if (error is StateError) {
    const Set<String> allowlist = <String>{
      'dialog-source-script-mismatch',
      'dialog-target-script-mismatch',
      'dialog-source-term-mismatch',
      'dialog-target-term-mismatch',
      'dialog-turn-already-active',
      'dialog-turn-interrupted',
      'dialog-session-failure',
    };
    final String text = error.toString();
    for (final String code in allowlist) {
      if (text.contains(code)) return code;
    }
  }
  return 'other';
}

int _percentile(List<int> values, double percentile) {
  if (values.isEmpty) return 0;
  final List<int> sorted = List<int>.of(values)..sort();
  final int index = ((sorted.length - 1) * percentile).ceil();
  return sorted[index];
}

enum _Speaker {
  a('A'),
  b('B');

  const _Speaker(this.label);

  final String label;
}

class _DialogTurnSpec {
  const _DialogTurnSpec({
    required this.scenario,
    required this.speaker,
    required this.pcmFile,
    required this.expectedSourceTerms,
    required this.expectedTargetTerms,
  });

  final String scenario;
  final _Speaker speaker;
  final File pcmFile;
  final List<String> expectedSourceTerms;
  final List<String> expectedTargetTerms;
}

class _DialogManifest {
  const _DialogManifest({
    required this.languageA,
    required this.languageB,
    required this.turns,
  });

  final String languageA;
  final String languageB;
  final List<_DialogTurnSpec> turns;

  static Future<_DialogManifest> load(File file) async {
    if (!await file.exists()) {
      throw const FormatException('dialog-manifest-missing');
    }
    final Object? decoded = jsonDecode(await file.readAsString());
    final Map<String, Object?> root = _objectMap(decoded, 'manifest');
    final String languageA = _nonEmptyString(root['languageA'], 'languageA');
    final String languageB = _nonEmptyString(root['languageB'], 'languageB');
    if (languageA == languageB) {
      throw const FormatException('dialog-languages-must-differ');
    }
    final Object? rawTurns = root['turns'];
    if (rawTurns is! List<Object?> ||
        rawTurns.isEmpty ||
        rawTurns.length > 50) {
      throw const FormatException('dialog-turn-count-invalid');
    }
    final RegExp safeScenario = RegExp(r'^[a-z0-9_-]{1,40}$');
    final List<_DialogTurnSpec> turns = <_DialogTurnSpec>[];
    var hasSpeakerA = false;
    var hasSpeakerB = false;
    for (final Object? rawTurn in rawTurns) {
      final Map<String, Object?> turn = _objectMap(rawTurn, 'turn');
      final String scenario = _nonEmptyString(turn['scenario'], 'scenario');
      if (!safeScenario.hasMatch(scenario)) {
        throw const FormatException('dialog-scenario-invalid');
      }
      final _Speaker speaker = switch (_nonEmptyString(
        turn['speaker'],
        'speaker',
      )) {
        'A' => _Speaker.a,
        'B' => _Speaker.b,
        _ => throw const FormatException('dialog-speaker-invalid'),
      };
      final File pcmFile = File(_nonEmptyString(turn['pcm'], 'pcm'));
      if (!await pcmFile.exists()) {
        throw const FormatException('dialog-pcm-missing');
      }
      final int length = await pcmFile.length();
      if (length <= 0 || length > _maximumFixtureBytes || length.isOdd) {
        throw const FormatException('dialog-pcm-size-invalid');
      }
      hasSpeakerA |= speaker == _Speaker.a;
      hasSpeakerB |= speaker == _Speaker.b;
      turns.add(
        _DialogTurnSpec(
          scenario: scenario,
          speaker: speaker,
          pcmFile: pcmFile,
          expectedSourceTerms: _stringList(
            turn['expectedSourceTerms'],
            'expected-source-terms',
          ),
          expectedTargetTerms: _stringList(
            turn['expectedTargetTerms'],
            'expected-target-terms',
          ),
        ),
      );
    }
    if (!hasSpeakerA || !hasSpeakerB) {
      throw const FormatException('dialog-must-cover-both-speakers');
    }
    return _DialogManifest(
      languageA: languageA,
      languageB: languageB,
      turns: List<_DialogTurnSpec>.unmodifiable(turns),
    );
  }

  static Map<String, Object?> _objectMap(Object? value, String field) {
    if (value is Map<String, Object?>) return value;
    throw FormatException('dialog-$field-invalid');
  }

  static String _nonEmptyString(Object? value, String field) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    throw FormatException('dialog-$field-invalid');
  }

  static List<String> _stringList(Object? value, String field) {
    if (value == null) return const <String>[];
    if (value is! List<Object?> || value.length > 10) {
      throw FormatException('dialog-$field-invalid');
    }
    final List<String> terms = value
        .map((Object? item) {
          final String term = _nonEmptyString(item, field);
          if (term.length > 40) throw FormatException('dialog-$field-invalid');
          return term;
        })
        .toList(growable: false);
    return List<String>.unmodifiable(terms);
  }
}

class _DialogProbe {
  _DialogProbe({required String apiKey, required String targetLanguageCode})
    : _session = GeminiLiveSession(
        apiKey: apiKey,
        targetLanguageCode: targetLanguageCode,
      ) {
    _subscription = _session.events.listen(_handleEvent);
  }

  final GeminiLiveSession _session;
  late final StreamSubscription<LiveEvent> _subscription;
  _TurnCollector? _currentTurn;
  Completer<void>? _readyWaiter;
  int failureEvents = 0;
  int reconnectEvents = 0;
  int promptTokens = 0;
  int responseTokens = 0;
  int totalTokens = 0;

  Future<void> connect() => _session.connect();

  Future<_TurnEvidence> runTurn(
    _DialogTurnSpec turn, {
    required String sourceLanguageCode,
    required String targetLanguageCode,
    required Duration timeout,
    required Duration switchDelay,
  }) async {
    if (_currentTurn != null) {
      throw StateError('dialog-turn-already-active');
    }
    if (!_session.isReady) {
      _readyWaiter = Completer<void>();
      if (!_session.isReady) {
        await _readyWaiter!.future.timeout(timeout);
      }
    }
    final Uint8List pcm = await turn.pcmFile.readAsBytes();
    final _TurnCollector collector = _TurnCollector(
      sourceLanguageCode: sourceLanguageCode,
      targetLanguageCode: targetLanguageCode,
      expectedSourceTerms: turn.expectedSourceTerms,
      expectedTargetTerms: turn.expectedTargetTerms,
      switchDelay: switchDelay,
    );
    _currentTurn = collector;
    try {
      for (var offset = 0; offset < pcm.length; offset += _chunkBytes) {
        final int end = (offset + _chunkBytes).clamp(0, pcm.length);
        _session.sendAudio(Uint8List.sublistView(pcm, offset, end));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      _session.endAudioStream();
      try {
        return await collector.completed.future.timeout(timeout);
      } on TimeoutException {
        stderr.writeln(
          'dialog_turn_timeout '
          'scenario=${turn.scenario} '
          'speaker=${turn.speaker.label} '
          'input_text_chars=${collector.inputTranscriptCharacters} '
          'output_text_chars=${collector.outputTranscriptCharacters} '
          'output_audio_bytes=${collector.outputAudioBytes} '
          'turn_complete=${collector.turnComplete}',
        );
        rethrow;
      }
    } finally {
      collector.dispose();
      if (identical(_currentTurn, collector)) {
        _currentTurn = null;
      }
    }
  }

  void _handleEvent(LiveEvent event) {
    switch (event) {
      case LivePhaseChanged(:final LiveSessionPhase phase):
        if (phase == LiveSessionPhase.ready) {
          final Completer<void>? waiter = _readyWaiter;
          if (waiter != null && !waiter.isCompleted) waiter.complete();
        } else if (phase == LiveSessionPhase.reconnecting) {
          reconnectEvents += 1;
        }
      case LiveInputTranscript(:final String text):
        _currentTurn?.addInputTranscript(text);
      case LiveOutputTranscript(:final String text):
        _currentTurn?.addOutputTranscript(text);
      case LiveAudioChunk(:final Uint8List bytes):
        _currentTurn?.addAudio(bytes.length);
      case LiveTurnComplete():
        _currentTurn?.markTurnComplete();
      case LiveInterrupted():
        _currentTurn?.fail(StateError('dialog-turn-interrupted'));
      case LiveUsageMetadata():
        promptTokens += event.promptTokenCount;
        responseTokens += event.responseTokenCount;
        totalTokens += event.totalTokenCount;
      case LiveSessionFailure():
        failureEvents += 1;
        _currentTurn?.fail(StateError('dialog-session-failure'));
      default:
        break;
    }
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _session.close();
  }
}

class _TurnCollector {
  _TurnCollector({
    required this.sourceLanguageCode,
    required this.targetLanguageCode,
    required this.expectedSourceTerms,
    required this.expectedTargetTerms,
    required this.switchDelay,
  });

  final String sourceLanguageCode;
  final String targetLanguageCode;
  final List<String> expectedSourceTerms;
  final List<String> expectedTargetTerms;
  final Duration switchDelay;
  final Stopwatch stopwatch = Stopwatch()..start();
  final Completer<_TurnEvidence> completed = Completer<_TurnEvidence>();
  final StringBuffer _inputTranscript = StringBuffer();
  final StringBuffer _outputTranscript = StringBuffer();
  int _outputAudioBytes = 0;
  int? _firstTranslationMilliseconds;
  int? _firstAudioMilliseconds;
  bool _turnComplete = false;
  Timer? _settleTimer;

  int get inputTranscriptCharacters => _inputTranscript.length;
  int get outputTranscriptCharacters => _outputTranscript.length;
  int get outputAudioBytes => _outputAudioBytes;
  bool get turnComplete => _turnComplete;

  void addInputTranscript(String text) {
    _inputTranscript.write(text);
    _scheduleCompletion();
  }

  void addOutputTranscript(String text) {
    _firstTranslationMilliseconds ??= stopwatch.elapsedMilliseconds;
    _outputTranscript.write(text);
    _scheduleCompletion();
  }

  void addAudio(int bytes) {
    _firstAudioMilliseconds ??= stopwatch.elapsedMilliseconds;
    _outputAudioBytes += bytes;
    _scheduleCompletion();
  }

  void markTurnComplete() {
    _turnComplete = true;
    _scheduleCompletion();
  }

  void fail(Object error) {
    _settleTimer?.cancel();
    if (!completed.isCompleted) completed.completeError(error);
  }

  void dispose() => _settleTimer?.cancel();

  void _scheduleCompletion() {
    if (!_hasRequiredOutput || completed.isCompleted) return;
    if (_turnComplete) {
      _settleTimer?.cancel();
      _completeNow();
      return;
    }
    // Live Translate currently emits all three output forms but may omit
    // serverContent.turnComplete and can continue emitting audio over silence.
    // The product's explicit A/B tap is the turn boundary, so model a user
    // switching after all required output first becomes available. Four seconds
    // is the default, but the delay is configurable for repeatable experiments.
    _settleTimer ??= Timer(switchDelay, _completeNow);
  }

  bool get _hasRequiredOutput =>
      _inputTranscript.isNotEmpty &&
      _outputTranscript.isNotEmpty &&
      _outputAudioBytes > 0 &&
      _firstTranslationMilliseconds != null &&
      _firstAudioMilliseconds != null;

  void _completeNow() {
    _settleTimer?.cancel();
    final String input = _inputTranscript.toString();
    final String output = _outputTranscript.toString();
    final int? firstTranslation = _firstTranslationMilliseconds;
    final int? firstAudio = _firstAudioMilliseconds;
    if (!_hasRequiredOutput ||
        firstTranslation == null ||
        firstAudio == null ||
        completed.isCompleted) {
      return;
    }
    if (!_containsExpectedScript(input, sourceLanguageCode)) {
      completed.completeError(StateError('dialog-source-script-mismatch'));
      return;
    }
    if (!_containsExpectedScript(output, targetLanguageCode)) {
      completed.completeError(StateError('dialog-target-script-mismatch'));
      return;
    }
    if (!_containsExpectedTerms(input, expectedSourceTerms)) {
      completed.completeError(StateError('dialog-source-term-mismatch'));
      return;
    }
    if (!_containsExpectedTerms(output, expectedTargetTerms)) {
      completed.completeError(StateError('dialog-target-term-mismatch'));
      return;
    }
    completed.complete(
      _TurnEvidence(
        inputTranscriptCharacters: input.length,
        outputTranscriptCharacters: output.length,
        outputAudioBytes: _outputAudioBytes,
        firstTranslationMilliseconds: firstTranslation,
        firstAudioMilliseconds: firstAudio,
        serverTurnComplete: _turnComplete,
      ),
    );
  }
}

bool _containsExpectedTerms(String text, List<String> termGroups) {
  final String normalized = _normalizeForTermMatching(text);
  return termGroups.every(
    (String group) => group
        .split('|')
        .map(_normalizeForTermMatching)
        .where((String term) => term.isNotEmpty)
        .any(normalized.contains),
  );
}

String _normalizeForTermMatching(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u3400-\u9fff]'), '');

bool _containsExpectedScript(String text, String languageCode) {
  if (languageCode.startsWith('zh')) {
    return RegExp(r'[\u3400-\u9fff]').hasMatch(text);
  }
  if (languageCode.startsWith('en')) {
    return RegExp('[A-Za-z]').hasMatch(text);
  }
  return text.trim().isNotEmpty;
}

class _TurnEvidence {
  const _TurnEvidence({
    required this.inputTranscriptCharacters,
    required this.outputTranscriptCharacters,
    required this.outputAudioBytes,
    required this.firstTranslationMilliseconds,
    required this.firstAudioMilliseconds,
    required this.serverTurnComplete,
  });

  final int inputTranscriptCharacters;
  final int outputTranscriptCharacters;
  final int outputAudioBytes;
  final int firstTranslationMilliseconds;
  final int firstAudioMilliseconds;
  final bool serverTurnComplete;
}
