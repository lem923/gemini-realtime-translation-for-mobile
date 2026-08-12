# realtime-translation — Quick Start

The repository is currently at Phase 0: requirements, architecture, and source-backed validation. The first runnable client will be an Android Flutter spike; iOS support follows on the same shared core.

## Prerequisites

- Git 2.40+
- Current stable Flutter SDK and its bundled Dart SDK (exact version will be pinned with the first scaffold)
- Android Studio, Android SDK, and a physical Android device
- Xcode and a physical iPhone are required when the iOS adapter phase begins
- A Gemini API key with access to `gemini-3.5-live-translate-preview`

The app uses a bring-your-own-key model. Enter the key at runtime through the settings UI. Never place a real key in source code, a committed `.env` file, a web build, or a mobile package.

## Set up this repository

```bash
git clone <repository-url>
cd realtime-translation
```

No dependency installation is required yet. Review these documents first:

1. [README.md](README.md) — product and architectural direction.
2. [docs/research/open-source-landscape.md](docs/research/open-source-landscape.md) — fork/no-fork analysis.
3. [docs/roadmap.md](docs/roadmap.md) — implementation gates and milestones.

## First implementation gate

The first runnable Android spike must measure:

- microphone capture and stable 16 kHz PCM conversion through an Android audio adapter;
- direct Live API connection using the user-entered Gemini API key;
- time to first translated audio and transcript;
- continuous playback queue stability;
- manual speaker switching, reconnect, and speaker echo behavior.

The shared Gemini/session/transcript code and platform audio contract must compile without Android dependencies. A later iOS spike will implement that contract with `AVAudioSession`, `AVAudioEngine`, `AVAudioConverter`, and Keychain.

The spike should not add accounts, databases, analytics, or a general AI-agent layer.
