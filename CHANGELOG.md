# Changelog

All notable changes to realtime-translation will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.12.0] - 2026-08-13

### Added

- Added an official `audioStreamEnd` protocol boundary and send it whenever a
  manual direction switch or conversation stop pauses the active microphone
  stream.
- Added a privacy-safe two-session dialogue harness for alternating travel
  scenarios, with configurable switch timing, source/target script checks,
  target semantic assertions, latency percentiles, and redacted usage totals.

### Fixed

- Discarded late input transcription, output transcription, audio, and turn
  completion events from an inactive directional session so an interrupted
  response cannot pollute or commit the next turn after switching back.
- Preserved the explicit user speaker tap as a reliable turn boundary when the
  preview translation model omits `serverContent.turnComplete`.

### Tests

- Added regressions for manual speaker switching without a server turn-complete
  event, inactive-session event isolation, and audio-stream-end serialization.
- Passed a real 10-turn Chinese/English dialogue over hotel, restaurant, taxi,
  shopping, and emergency fixtures with nine direction switches, three output
  forms on every turn, semantic target checks, zero failures, and zero reconnects.
- Expanded the automated suite to 64 passing tests at 85.4% line coverage.

## [0.11.0] - 2026-08-13

### Added

- Added privacy-safe Gemini prompt, response, and total Token counters to the
  in-app diagnostic report, aggregated across both warm directions and reset at
  each conversation start.
- Added a secret-safe long-session smoke tool that sends production-paced PCM
  for 21 minutes before requiring source text, translated text, and translated
  PCM.

### Changed

- Enabled Live API sliding-window context compression so audio sessions are not
  constrained by the service's default uncompressed context duration.
- Extended the real API smoke report with non-sensitive usage counters.

### Fixed

- Normalized local replacement closes to WebSocket code `1000`, preventing an
  unhandled Dart exception when Gemini rotates a long-running connection with
  server code `1001 Going Away`.
- Removed the duplicate reconnect-phase notification emitted while a scheduled
  retry actually started, keeping diagnostics at one event per retry attempt.

### Tests

- Added protocol fixtures for context compression and defensive usage-metadata
  parsing, plus per-response aggregation coverage across both directions.
- Added a logical 20-minute, 12,000-chunk, 240-turn media run that verifies
  bounded history, replay eviction, output accounting, and muted playback.
- Passed a real 21-minute, 12,212-chunk Live API run through two server
  connection rotations with zero failures, followed by successful source text,
  translated text, and translated audio output.
- Added a local WebSocket regression that performs a real `1001` server close,
  reconnects, reaches ready again, and proves no asynchronous error escapes.
- Added structural coverage for resumption-handle serialization and resumable
  `goAway` parsing.
- Expanded the automated suite to 61 passing tests.

## [0.10.0] - 2026-08-13

### Changed

- Face-to-face mode now places the live source transcript on the selected
  speaker's half and the translated transcript on the opposite listener's half.
- Completed source and translated text remain visible until a new utterance or
  direction starts, without leaking a completed turn across language changes.
- Both rotated and upright halves fill the same width and explicitly identify
  their current `讲话` or `译文` role.

### Fixed

- Restored a real accessibility tap action for both face-to-face halves; Android
  now exposes each half as a clickable button with the correct selected state.
- Long transcripts remain bounded on compact phone layouts.

### Tests

- Added A-to-B, B-to-A, completed-turn retention, stale-text replacement,
  long-text, equal-width, live-region, selected-state, and tap-action coverage,
  bringing the automated suite to 57 tests.

## [0.9.0] - 2026-08-13

### Changed

- Replaced the ambiguous boolean microphone status with a typed
  `notDetermined`, `granted`, and `denied` platform contract prepared for iOS.
- Android now records only whether a permission request was answered or had
  previously been granted, using private non-sensitive application preferences.

### Fixed

- A remembered-key cold start before the first microphone request no longer
  displays a false denial or sends the user directly to system settings.
- A real denial and a later runtime revocation remain distinguishable and
  recoverable after Android process death.

### Tests

- Added wire-decoding, method-channel acknowledgement, first-request, denial,
  and revocation state coverage, bringing the automated suite to 55 tests.

## [0.8.0] - 2026-08-13

### Added

- Added an iOS-ready microphone-permission gateway with read-only status,
  native change events, and app-settings navigation.
- Added recoverable permission actions in both the error banner and primary
  control, including automatic status refresh after returning from settings.
- Added live-region status/error semantics, explicit face-to-face speaker
  labels, and 48 px minimum language/settings targets.
- Added controller and Material widget coverage for cold-start denial,
  in-session revocation cleanup, recovery, settings navigation, and accessible
  state announcements.

### Fixed

- Runtime microphone revocation now terminates capture, Gemini sessions, and
  playback immediately instead of leaving a stale listening session.
- Restoring a remembered key no longer risks requesting microphone permission
  during application initialization.

## [0.7.0] - 2026-08-13

### Added

- Persist the last valid A/B language pair as one non-sensitive local preference
  without storing transcript or audio content.
- Added explicit translating, offline, and rate-limited conversation states with
  Material status and recovery labels; connecting and automatic network waiting
  remain explicitly cancellable.
- Added typed Gemini failure categories for authentication, quota, offline,
  configuration, service, and unknown failures.
- Added preference corruption, language restore, typed protocol/state, initial
  disconnect race, and responsive UI regression coverage.

### Fixed

- A connection Future that failed after emitting an offline event no longer
  overwrites the actionable offline state with a generic failure.
- Invalid, unsupported, or duplicate persisted language pairs now safely fall
  back to Simplified Chinese and English.

## [0.6.0] - 2026-08-13

### Added

- Added a Material 3 replay control to every completed turn that has translated
  speech, including an explicit stop state.
- Added memory-only replay retention capped at 30 seconds per turn and 8 MiB
  total; oldest audio is evicted without removing transcript history.
- Added controller and widget coverage for complete replay, immediate cancel,
  microphone suppression, fresh-live-output priority, oversized turns, cache
  eviction, and the Material replay state.

### Changed

- Replay feeds the native player in paced 100 ms chunks and releases idle audio
  resources on completion.
- Mute, history clear, speaker switch, conversation stop, system interruption,
  and newly arriving translated speech cancel old replay immediately.

## [0.5.0] - 2026-08-13

### Added

- Added a typed native-to-Flutter audio interruption stream. Android audio
  focus loss now stops microphone capture, both Gemini sessions, and translated
  playback instead of leaving a silently paused or privacy-sensitive session.
- Added redacted diagnostics for system audio interruptions, actual output
  route, and whether the app currently owns Android audio focus.
- Added controller and platform-metric regression coverage plus an Android API
  36 end-to-end focus-stealing test using an isolated local helper service.

### Changed

- Centralized Android audio-focus ownership in the native playback adapter and
  disabled the recorder plugin's competing focus request.
- Explicit stop, lifecycle stop, terminal failure, and system interruption now
  release `AudioTrack`, communication mode, and audio focus. A later start
  configures them again from a clean state.

### Fixed

- Stopping translation no longer leaves the application holding Android's
  communication audio mode or audio focus.

## [0.4.0] - 2026-08-13

### Changed

- Treat a manual A/B speaker change as an immediate barge-in boundary: enter a
  non-listening state, discard translated speech queued for the previous
  direction, reset the echo guard, connect the selected direction, and only
  then reopen microphone routing.

### Added

- Added deterministic coverage for queued translated audio, microphone routing
  while a flush is pending, playback-flush degradation, and rapid A/B/A races.
- Exercised ten consecutive direction changes against the real Gemini service
  on an Android API 36 emulator while translated audio was streaming.

## [0.3.0] - 2026-08-13

### Added

- Added a local, redacted runtime diagnostics report for first source text,
  first translated text, first translated audio, microphone sends, echo-guard
  suppression, direction switches, reconnects, failures, and completed turns.
- Added Android native playback queue depth, queue ceiling, and dropped-chunk
  metrics to the shared platform contract.
- Added a Material 3 diagnostics dialog with selective text and clipboard export;
  the report never contains API keys, audio payloads, or transcript content.
- Added deterministic setup-disconnect, diagnostic privacy, native-metric,
  terminal-resource-release, microphone-failure, and UI tests.

### Fixed

- Terminal Gemini, microphone-stream, microphone-startup, and speaker-switch
  failures now release capture, both warm sessions, and playback before retry.
- A WebSocket close during the setup-ready race no longer leaks an unhandled
  asynchronous `Completer` error into the Flutter runtime log.

## [0.2.0] - 2026-08-13

### Added

- Added regression coverage for lifecycle cancellation, simultaneous stops,
  stale speaker switches, long sessions, cumulative echo suppression, playback
  failures, and retryable versus terminal Gemini errors.
- Added native Android playback queue metrics and a 1.5-second latency ceiling.

### Changed

- Serialized translated PCM writes and flushes, including partial native
  `AudioTrack.write` handling.
- Bounded individual transcripts to 8,000 characters and conversation history
  to the latest 200 turns.
- Hardened reconnect behavior, lifecycle shutdown, Android backup policy, and
  cleartext-network policy.
- Release builds now require an external private signing key and can no longer
  silently use the Android debug certificate.

## [0.1.0] - 2026-08-13

### Added

- Initial project structure and Alcove project documentation.
- Open-source landscape survey and no-fork decision.
- Mobile-first product direction, roadmap, and initial authentication architecture (later superseded by BYOK).
- Product narrowed to a client-only BYOK conversation translator with manual A/B speaker selection and simultaneous translated audio/text.
- Expanded exact-match GitHub review and selective MIT-component reuse recommendation.
- Added the Android-first Flutter application with Material 3 standard and face-to-face layouts.
- Added BYOK validation, memory-only default handling, and opt-in secure persistence.
- Added dual directional Gemini Live sessions, manual A/B routing, transcripts, reconnect/resumption, and translated PCM playback.
- Added searchable official language metadata, native Android microphone/audio support, and iOS-ready platform boundaries.
- Added unit, controller, responsive widget, emulator, and redacted real-API smoke validation.
- Worked around the preview raw-WebSocket transcription-field schema mismatch verified against the live service.
