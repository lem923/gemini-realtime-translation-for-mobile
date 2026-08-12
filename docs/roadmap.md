# Roadmap

## Phase 0 — Foundation (current)

- Define the travel conversation product and latency budget.
- Survey existing open-source projects and decide whether to fork.
- Establish the client-only BYOK architecture and local key-handling rules.
- Define device validation and preview-model risks.

Exit gate: project documentation is internally consistent and the first spike has explicit measurements.

## Phase 1 — Android audio and API spike

- Capture microphone audio and emit stable 16 kHz mono PCM chunks.
- Add an API-key settings/validation flow; a missing or invalid key blocks translation.
- Connect directly to Gemini Live Translate from the phone using the user-entered key.
- Play 24 kHz translated PCM without gaps or unbounded buffering.
- Assemble source and translated transcript deltas.
- Measure time to first transcript, time to first audio, jitter, reconnect time, and memory growth.

Exit gate: reliable one-direction translation on the defined physical Android device matrix with recorded latency and queue results; the shared core has no Android-only dependencies.

## Phase 2 — Two-way travel conversation MVP

- Add language A/B selection and two large speaker selectors.
- Add face-to-face and single-reader layouts.
- Let the user explicitly select person A or person B as the active speaker.
- Maintain two ready translation directions where measurements justify it, activating only the selected direction.
- Add tap-to-talk or start/stop capture; automatic speaker detection remains out of scope.
- Add transcript history, replay, mute, and clear controls.
- Handle interruption, direction change, permission denial, offline state, quota errors, and model disconnects.

Exit gate: two people can complete representative hotel, restaurant, taxi, shopping, and emergency dialogues on one phone.

## Phase 3 — Android hardening and release

- Run noisy-street, speakerphone, headset, and weak-network tests.
- Add privacy notice, explicit retention behavior, and redacted telemetry.
- Add CI, Flutter integration tests, accessibility checks, signing guidance, and Android release packaging.

Exit gate: defined latency/reliability targets pass on the supported Android device matrix.

## Phase 4 — iOS adapter and parity

- Implement the existing audio interface with `AVAudioSession`, `AVAudioEngine`, and `AVAudioConverter`.
- Implement Keychain-backed optional key persistence and iOS permission/lifecycle handling.
- Validate route changes, interruptions, speaker/receiver/Bluetooth behavior, echo control, and background transitions.
- Run the shared conversation, protocol, transcript, reconnect, and queue test suites unchanged.
- Package and release the iOS application after Android behavior reaches parity.

Exit gate: core travel scenarios and latency/reliability targets pass on the supported physical iPhone matrix without forking shared product logic.

## Deferred

- Multi-party rooms or broadcast translation.
- Video/vision input and general Gemini agent features.
- Backend services, user accounts, cloud transcript storage, analytics, or payments.
- Offline translation or a second provider.
