# Changelog

All notable changes to realtime-translation will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
