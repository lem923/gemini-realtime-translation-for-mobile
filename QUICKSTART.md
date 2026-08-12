# realtime-translation — Quick Start

The repository contains a runnable Android-first Flutter preview. iOS support follows on the same shared Dart product, protocol, conversation, and transcript core.

## Prerequisites

- Git 2.40+
- Flutter 3.44 or later with its bundled Dart SDK
- Android SDK 36 or later, JDK 17, and an emulator or physical Android device
- Xcode and a physical iPhone are required when the iOS adapter phase begins
- A Gemini API key with access to `gemini-3.5-live-translate-preview`

The app uses a bring-your-own-key model. Enter the key at runtime through the settings UI. Never place a real key in source code, a committed `.env` file, a web build, or a mobile package.

## Set up this repository

```bash
git clone https://github.com/lem923/gemini-realtime-translation-for-mobile.git
cd gemini-realtime-translation-for-mobile
flutter pub get
flutter doctor
```

Run the automated checks:

```bash
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test
```

Start the Android app:

```bash
flutter run
```

In the app, set language A and B, enter your own API key, leave “remember” off unless local persistence is desired, then tap **开始翻译**. Tap A or B whenever the person speaking changes.

Build an installable APK:

```bash
flutter build apk --release
```

The output is `build/app/outputs/flutter-apk/app-release.apk`. The repository preview uses the generated debug signing key for installable release-mode testing; configure a private release keystore before store distribution.

Review these documents for project context:

1. [README.md](README.md) — product and architectural direction.
2. [docs/research/open-source-landscape.md](docs/research/open-source-landscape.md) — fork/no-fork analysis.
3. [docs/roadmap.md](docs/roadmap.md) — implementation gates and milestones.

## Optional real API smoke test

`tool/live_smoke.dart` validates the protocol without printing the key, transcripts, or audio. Provide raw signed 16-bit little-endian, 16 kHz mono PCM:

```bash
GEMINI_API_KEY='your-key' \
LIVE_TEST_PCM='/absolute/path/to/input.pcm' \
dart run tool/live_smoke.dart
```

The command passes only when it receives a source transcript, translated transcript, and translated PCM audio. Do not put the key in a committed shell file or `.env` file.

## Remaining Android hardening gate

The first runnable Android spike must measure:

- microphone capture and stable 16 kHz PCM conversion through an Android audio adapter;
- direct Live API connection using the user-entered Gemini API key;
- time to first translated audio and transcript;
- continuous playback queue stability;
- manual speaker switching, reconnect, and speaker echo behavior.

The shared Gemini/session/transcript code and platform audio contract compile without Android dependencies. A later iOS spike will implement that contract with `AVAudioSession`, `AVAudioEngine`, `AVAudioConverter`, and Keychain.

The spike should not add accounts, databases, analytics, or a general AI-agent layer.
