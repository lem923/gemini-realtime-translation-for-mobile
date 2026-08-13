# Changelog

All notable changes to realtime-translation will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.21.0] - 2026-08-13

### Changed

- The microphone path now applies an energy-based speech gate with adaptive
  noise floor and hysteresis. Ambient silence and noise are held locally
  instead of being sent to Gemini, and each utterance end sends
  `audioStreamEnd` so the server finalizes the turn promptly. This stops the
  server from continuously translating background noise, which previously kept
  translated playback running and starved later sentences.

### Added

- Diagnostics now report held silence chunks and detected utterances alongside
  sent and suppressed counters.

### Tests

- 116 Flutter tests pass, including speech-gate, utterance-finalization, and
  noise-floor regression suites; Android host tests and lint pass. On-device
  mock and real-Gemini runs confirmed silence is held with zero transport
  chunks and the session stays healthy.

## [0.20.0] - 2026-08-13

### Changed

- Streaming now keeps its Gemini sessions and microphone across audio-focus
  interruptions. An interruption retires only the interrupted playback run:
  translated text keeps flowing and the volume toggle restores voice, matching
  the design that only explicit stop, direction change, or permission
  revocation ends a stream.
- Unexpected microphone capture end or failure now restarts capture with a
  bounded recovery budget instead of immediately terminating the conversation.
  Each gap sends `audioStreamEnd` so the server commits the interrupted turn.
- The Live setup now requests a 500 ms server-side silence window
  (`automaticActivityDetection.silenceDurationMs`) so turns finalize sooner
  after speech stops.
- Speaker cards now separate their tap zones: the card body selects the
  speaker while the language name sits in a visually distinct pill that opens
  the language picker, with its own tooltip and accessibility label.

### Fixed

- Capture recovery replaces the active subscription before cancelling the
  previous one, so an already-closed replacement stream can no longer strand
  the conversation in a false listening state.

### Tests

- 110 Flutter tests pass; Android host tests and lint pass; GitHub Actions CI
  is green. A mock-server emulator matrix verified session persistence,
  direction-switch turn boundaries, goAway resumption, and 1001-close
  reconnects; a real Gemini run validated the new setup fields, stable
  60-second sessions, usage metadata, and translated audio. The signed
  release APK passed signature, alignment, and secret scans and clean-installed
  plus upgraded on Android API 26 and API 36 emulators with a real-Gemini
  session on API 36.

## [0.19.0] - 2026-08-13

### Added

- Added an original Android/iOS launcher icon and branded launch artwork built
  around bidirectional speech bubbles, exchange arrows, and a voice waveform.
- Added a public project-status report and an evidence-gated Android-first/iOS-
  later roadmap.
- Added face-to-face status/error overlays, complete long-transcript scrolling,
  explicit Google processing/privacy disclosure, and Material 3 accessibility
  checks for light/dark themes, RTL, 200% text scale, contrast, labels, and tap
  targets.

### Changed

- Speaker changes now retire the previous active directional session before
  warming a clean replacement, preventing an old response from crossing a later
  reactivation boundary.
- Native translated-audio queues and failure events now carry playback
  generations. Flush, focus loss, stop, and recovery cannot replay an old chunk
  or let a delayed failure mutate a newer playback run.
- Authentication failure clears the active key immediately; secure-storage
  deletion is bounded and reports an actionable warning if a device copy cannot
  be confirmed removed.

### Fixed

- Made recorder and native playback teardown authoritative before media owners
  can be reused, while keeping socket/subscription cleanup isolated and bounded.
- Hardened Gemini session replacement/close against throwing or hanging channel
  cancellation and made concurrent close calls share one operation.
- Reject malformed, non-audio, non-mono, or non-24 kHz inline PCM before it can
  reach the fixed Android output format.
- Treat capture completion and Gemini interruption as explicit terminal/turn
  boundaries, and retire a recorder backend whose native stop fails.

### Tests

- Passed all 108 Flutter tests at 89.1% line coverage, 17 Android host tests,
  Flutter analysis, Android lint, formatting, and a branded signed release APK
  build.
- Verified the signed release APK on clean Android API 26 and API 36 emulator
  installs, including cold start, portrait/landscape layouts, face-to-face mode,
  and the API Key/privacy flow without crashes or layout errors.
- Passed a real two-turn Chinese/English Gemini dialogue with one manual
  direction switch, source and translated text, 204,000 bytes of translated
  audio, zero failures, and zero reconnects.

## [0.18.0] - 2026-08-13

### Fixed

- Closing a Gemini session while its setup handshake is still pending now
  cancels that connection immediately instead of leaving its setup future
  waiting for the transport timeout or emitting a late event to a closed stream.
- Conversation stop and disposal now release recorder subscriptions, both warm
  Gemini sessions, playback, and platform audio independently. A failure in one
  adapter or socket close can no longer abort cleanup of the remaining resources.

### Tests

- Added deterministic regressions for setup-time cancellation without unhandled
  asynchronous errors and for failure-isolated cleanup when one session close
  throws. Passed all 78 Flutter tests at 86.1% line coverage, six Android host
  tests, Flutter analysis, Android lint, formatting, and debug compilation.
- On Android API 36 with a real Gemini session, backgrounding an active 16 kHz
  capture released every recording client and restored `MODE_NORMAL` while the
  app process remained alive; returning showed a clean ready state. API 26 kept
  its actionable fail-closed microphone behavior with no active recorder.

## [0.17.0] - 2026-08-13

### Added

- Added typed Android playback-route events so the shared conversation state
  can react to the route actually selected by the communication audio stack.

### Changed

- Made half-duplex echo protection route-aware. Speaker, earpiece, and unknown
  shared-phone routes now suppress microphone forwarding through the complete
  translated playback plus a conservative 300 ms acoustic tail. Wired,
  Bluetooth, USB, hearing-aid, and HDMI routes retain an 80 ms low-latency tail.
- Recompute the active protection deadline immediately when the output route
  changes, while preserving Android echo cancellation, noise suppression, and
  automatic gain control.

### Tests

- Added event-decoding, complete route-policy, shared-phone tail, and isolated
  route latency regressions. Passed all 76 Flutter tests at 86.1% line coverage,
  six Android host tests, Flutter analysis, Android lint, and debug compilation.
- On Android API 36 with a real Gemini session, diagnostics reported the speaker
  route and hundreds of microphone chunks suppressed during translated output;
  muting playback resumed microphone forwarding. Stop released all audio
  resources. API 26 retained its actionable fail-closed recorder behavior.

## [0.16.0] - 2026-08-13

### Fixed

- Isolated microphone startup ownership by capture generation so a cancelled
  startup can no longer time out later and stop a newer, healthy recording.
- Made stop actively cancel a pending first-PCM health check instead of waiting
  for its startup timeout, while ignoring stale native audio callbacks.

### Tests

- Added deterministic regressions proving pending startup cancellation is
  immediate and a cancelled startup cannot stop the next capture.
- Passed all 72 Flutter tests at 86.1% line coverage, six Android host tests,
  Flutter analysis, Android lint, formatting, and debug APK compilation.
- On Android API 36, cancelled a real Gemini connection, restarted it, observed
  stable translation plus simultaneous 16 kHz communication capture and 24 kHz
  translated playback, then verified complete resource release. API 26 retained
  the actionable fail-closed behavior for its broken legacy microphone HAL.

## [0.15.0] - 2026-08-13

### Fixed

- Prevented a failed native recorder initialization from leaving the app in a
  false listening state. Capture startup now observes the recorder state-error
  channel and requires the first complete PCM chunk within three seconds.
- Preserved that first PCM chunk for Gemini instead of consuming it as a health
  probe. Early error, closed stream, and silent timeout paths release recorder,
  Gemini sessions, communication mode, focus, and route before retry.
- Added a specific microphone-startup recovery message instead of mislabeling a
  native capture failure as an API Key or network problem.

### Tests

- Added deterministic first-chunk, native-start-error, and silent-timeout
  gateway tests plus controller cleanup/message coverage.
- Passed all 70 Flutter tests at 86.0% line coverage, six Android host tests,
  Flutter analysis, Android lint, and debug APK compilation.
- An Android API 26 emulator with a nonfunctional legacy microphone HAL now
  fails closed with an actionable message and complete audio-resource release;
  the same build completes the first-chunk handshake, real Gemini startup, and
  `VOICE_COMMUNICATION` capture on API 36.

## [0.14.0] - 2026-08-13

### Fixed

- Configured Android microphone capture with the voice-communication source so
  the 16 kHz input path receives the platform's VoIP tuning instead of relying
  on the recorder default.
- Disabled the recorder plugin's independent Bluetooth route management. The
  native communication adapter is now the only component that selects and
  clears the matching input/output route.

### Tests

- Added three capture-contract tests for the Gemini PCM format, Android
  communication source, speech preprocessing, and single route/focus owner.
- Passed all 67 Flutter tests at 85.4% line coverage, six Android host tests,
  Flutter analysis, Android lint, and a debug APK build.
- On Android API 36, verified an active 16 kHz `VOICE_COMMUNICATION` recording,
  24 kHz voice-communication playback, speaker route, and one communication
  mode owner. Manual stop removed the recording client, restored normal mode,
  and cleared the preferred communication device without audio errors or app
  crashes.

## [0.13.0] - 2026-08-13

### Added

- Added an external-device-aware Android communication route policy with
  deterministic fallback, device add/remove observation, and six Kotlin unit
  tests enforced alongside Android lint in CI.

### Changed

- Classified translated PCM playback as voice communication instead of
  accessibility-service audio so playback follows the same Android
  communication strategy as microphone capture.
- Preserved an active external communication route and prioritized supported
  wired, USB, hearing-aid, and Bluetooth devices over the built-in speaker.
  Phones with no external route still use the speaker for shared conversation.
- On Android 8–11, speakerphone is no longer forced when the system reports an
  external output. No scanning, pairing, or nearby-device permission was added.

### Tests

- Passed all 64 Flutter tests at 85.4% line coverage, six Android host tests,
  Flutter analysis, Android lint, and app-scoped Android compilation.
- Verified API 36 communication-mode ownership, bare-phone speaker selection,
  and complete mode/device release after stop without crashes or permission
  failures.
- Verified standard and face-to-face layouts at 360 × 640 dp and 130% font
  scaling in portrait and landscape with no Flutter overflow or crash events.
- Repeated a real 10-turn Chinese/English hotel, restaurant, taxi, shopping,
  and emergency dialogue with source text, translated text, translated audio,
  nine direction switches, zero failures, and zero reconnects.

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
