# Repository instructions

## Scope

This repository builds a mobile-first, two-way travel interpreter around the Google Gemini Live Translate model. Keep the latency-critical audio path small and observable.

## Before implementation

1. Query Alcove for product, architecture, conventions, decisions, progress, debt, and environment-variable guidance.
2. Verify current Gemini Live API behavior against official Google documentation; the target model is a preview and its contract may change.
3. Review `docs/research/open-source-landscape.md` before importing third-party code.

## Engineering constraints

- This is a BYOK client: accept a user-entered Gemini API key at runtime, but never hard-code, commit, bundle, upload, or log it.
- Keep the key in memory by default. Any “remember key” option must be explicit and use Android Keystore-backed or iOS Keychain-backed storage.
- Keep the audio path direct from the phone to Gemini unless measurements justify a relay.
- Build the product in Flutter, with Android as the first implementation/release target and iOS as a planned second target.
- Keep Android audio, lifecycle, permissions, and secure-storage code behind platform interfaces; shared Dart code must remain reusable by iOS.
- The user explicitly selects the active speaker/direction; do not add automatic speaker detection to MVP.
- Treat 100 ms input chunks, 16 kHz mono PCM input, and 24 kHz mono PCM output as verified defaults, not magic constants; centralize them.
- Separate microphone capture, PCM conversion, transport, session state, transcription assembly, and playback queue logic.
- Record latency at capture, send, first transcript, first audio, and playback boundaries.
- Do not add a backend, token broker, databases, user accounts, analytics, or agent tools to the MVP without an accepted architecture decision.
- Do not copy code from a repository until its license and attribution requirements are recorded.

## Quality bar

- Enable Dart strict analysis; avoid `dynamic` in protocol, audio, and state-machine code.
- Keep Kotlin and Swift platform-channel APIs small, typed, versioned, and symmetric where platform behavior permits.
- Unit-test state machines and transcript delta assembly.
- Device-test every Android audio-path change; run the same contract suite against iOS when that adapter is introduced.
- Never log audio payloads, API keys, or conversation transcripts by default.
- Use Conventional Commits and keep public docs synchronized with material behavior changes.
