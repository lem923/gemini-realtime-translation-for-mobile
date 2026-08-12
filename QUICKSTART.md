# realtime-translation — Quick Start

The repository contains a runnable Android-first Flutter preview. iOS support follows on the same shared Dart product, protocol, conversation, and transcript core.

## Prerequisites

- Git 2.40+
- Flutter 3.47.0 with its bundled Dart 3.13 SDK
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

For device hardening, open **API Key 与隐私 → 查看运行诊断** after a
conversation. The selectable/copyable report contains only timing and counters:
it intentionally excludes the API key, audio payloads, source transcript, and
translated transcript.

Build a local debug APK:

```bash
flutter build apk --debug
```

For a signed release APK, provide a private keystore entirely outside the
repository:

```bash
ANDROID_KEYSTORE_PATH='/absolute/path/to/upload.jks' \
ANDROID_KEYSTORE_PASSWORD='store-password' \
ANDROID_KEY_ALIAS='upload' \
ANDROID_KEY_PASSWORD='key-password' \
flutter build apk --release
```

The output is `build/app/outputs/flutter-apk/app-release.apk`. Release builds
fail closed when any signing variable is missing, preventing accidental
publication with the Android debug certificate. Never commit the keystore or
its credentials.

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

For long-session verification, keep the same secret-handling rules and use the
bounded media harness. For 1,260 seconds (21 minutes) it sends 100 ms silent PCM
chunks at production pace, then sends the speech fixture and requires all three
output forms:

```bash
GEMINI_API_KEY='your-key' \
LIVE_TEST_PCM='/absolute/path/to/input.pcm' \
LIVE_TEST_IDLE_SECONDS=1260 \
dart run tool/live_long_session_smoke.dart
```

Progress and the final report contain only audio-chunk totals, readiness,
reconnect/failure counts, payload sizes, and Token counters. They never print the
key, audio, or transcript content.

For a multi-turn, two-direction travel check, create a private manifest that
points to generated or otherwise non-sensitive 16 kHz mono PCM fixtures. Do not
commit the manifest or audio:

```json
{
  "languageA": "zh-Hans",
  "languageB": "en",
  "turns": [
    {
      "scenario": "hotel",
      "speaker": "A",
      "pcm": "/absolute/path/to/hotel-a.pcm",
      "expectedTargetTerms": ["reservation|booking"]
    },
    {
      "scenario": "hotel",
      "speaker": "B",
      "pcm": "/absolute/path/to/hotel-b.pcm",
      "expectedTargetTerms": ["护照|证件"]
    }
  ]
}
```

Each expected-term string is one required semantic group; alternatives within
a group are separated by `|`. Optional `expectedSourceTerms` uses the same
format. Run the redacted harness with at least one turn for each speaker:

```bash
GEMINI_API_KEY='your-key' \
LIVE_TEST_DIALOG_MANIFEST='/absolute/path/to/manifest.json' \
LIVE_TEST_SWITCH_DELAY_MILLISECONDS=4000 \
dart run tool/live_dialog_smoke.dart
```

The harness sends `audioStreamEnd` after each fixture and passes only when every
turn has source text, translated text, translated PCM audio, the expected
language scripts, and all requested semantic groups. Output contains only safe
scenario labels, counts, latency metrics, event totals, and Token totals.

## Remaining Android hardening gate

The first runnable Android spike must measure:

- microphone capture and stable 16 kHz PCM conversion through an Android audio adapter;
- direct Live API connection using the user-entered Gemini API key;
- time to first translated audio and transcript;
- continuous playback queue stability;
- manual speaker switching, reconnect, and speaker echo behavior.

The shared Gemini/session/transcript code and platform audio contract compile without Android dependencies. A later iOS spike will implement that contract with `AVAudioSession`, `AVAudioEngine`, `AVAudioConverter`, and Keychain.

The spike should not add accounts, databases, analytics, or a general AI-agent layer.
