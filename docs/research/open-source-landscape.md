# Open-source landscape: Gemini Live travel translation

**Survey date:** 2026-08-12  
**Decision:** Do not fork an existing repository for the initial foundation.

## Evaluation criteria

A suitable base should provide most of the following:

1. Native use of `gemini-3.5-live-translate-preview`, not prompt-based translation through a general live agent.
2. Bidirectional, face-to-face conversation on a single phone.
3. Speech-to-speech output plus source and translated transcripts.
4. Mobile-first audio capture and playback with echo/reconnect handling.
5. A secure key architecture suitable for distribution.
6. Recent activity, tests/automation, multiple contributors or releases, and a permissive license.

## Shortlist

Repository statistics are a point-in-time snapshot from GitHub on the survey date.

| Project | Snapshot | Fit | Decision |
|---|---:|---|---|
| [kizuna-ai-lab/sokuji](https://github.com/kizuna-ai-lab/sokuji) | 1,065 stars, 142 forks, 9 contributors, 10 workflows, AGPL-3.0 | Mature two-way translator with Gemini support, but built for desktop/browser-extension meeting audio; its advertised automatic two-way mode is provider-specific rather than a focused Gemini mobile travel flow. The large multi-provider codebase and AGPL obligations are poor fits for a small mobile product foundation. | Reference only |
| [google-gemini/gemini-live-api-examples](https://github.com/google-gemini/gemini-live-api-examples) | 465 stars, 167 forks, 45 commits | Official protocol examples, including ephemeral-token WebSockets and a translation CLI. It is the strongest API reference, but not a mobile product or bidirectional travel UI, and the repository itself did not expose a repository-level SPDX license in the GitHub metadata snapshot. | Protocol reference |
| [google-gemini/gemini-live-translate-livekit](https://github.com/google-gemini/gemini-live-translate-livekit) | 11 stars, 10 forks, 50 commits, Apache-2.0 | Official, production-minded broadcast translation with Next.js and LiveKit. Designed for one speaker to many listeners; LiveKit adds a media hop and operational scope that a single-phone conversation does not need. | Architecture reference |
| [livekit-examples/gemini-live-translate](https://github.com/livekit-examples/gemini-live-translate) | 20 stars, 8 forks, 6 commits, MIT | Genuine multi-participant, multi-language call translation. Useful routing reference, but requires LiveKit Cloud plus one Gemini session per speaker/target pair. It solves remote calls rather than two travelers sharing a phone. | Routing reference |
| [NA-DEGEN-GIRL/translator](https://github.com/NA-DEGEN-GIRL/translator) | 0 stars, 0 forks, 1 contributor, no releases/workflows, MIT | Closest UX match: Flutter Android/web, face-to-face layout, transcripts, audio, manual direction, BYOK, and dual Gemini sessions. It also contains a large unrelated OpenAI pipeline and lacks releases/CI/community maturity, so it remains a reference rather than a base. | UX reference only |
| [luoxiaoxin123/live-translate](https://github.com/luoxiaoxin123/live-translate) | 29 stars, 1 fork, Apache-2.0 | Recent Android implementation using native Gemini translation, microphone/media capture, overlay captions, and translated audio. It is a one-direction subtitle/media tool rather than a face-to-face conversation app. | Android audio reference |
| [himomohi/AirTranslate](https://github.com/himomohi/AirTranslate) | 379 stars, 37 forks, Apache-2.0 | Active and well-adopted Swift translation app, but macOS-focused rather than a phone travel interpreter. | Swift/audio reference |
| [ZackAkil/immersive-language-learning-with-live-api](https://github.com/ZackAkil/immersive-language-learning-with-live-api) | 482 stars, 171 forks, Apache-2.0 | Mature mobile-friendly web/audio architecture and travel role-play UX, but it is a Gemini Live language-learning agent, not native continuous Live Translate. | Web/audio reference |

## Conclusion

There is a mature adjacent project (`sokuji`) and several strong official examples, but no mature, permissively licensed repository matching the intended product closely enough to justify inheriting its architecture.

The recommended path is:

1. Start a clean Apache-2.0 repository.
2. Follow Google's native Live Translate contract directly.
3. Borrow architectural ideas, not source code, from the shortlist unless a later decision records license and attribution details.
4. Use Flutter for shared Android/iOS product and protocol code, while keeping latency-critical audio behind native platform adapters.

## Reassessment after narrowing the product

After confirming that the intended product is a Google Translate-style BYOK tool with manual A/B speaker selection and both translated audio and text, the candidates can be ranked more precisely.

### 1. Best reusable reference: `NA-DEGEN-GIRL/translator`

[Repository](https://github.com/NA-DEGEN-GIRL/translator) — MIT.

It already implements the same core interaction in Flutter for Android and Web:

- face-to-face split view with one side rotated;
- two user-selected languages and manual direction microphones;
- two warm `gemini-3.5-live-translate-preview` sessions;
- only the selected direction receives microphone PCM;
- input and output transcripts;
- translated PCM playback toggle;
- user-entered Google API key, Android secure storage, and browser-local storage;
- Android audio routing, PCM playback, half-duplex echo guard, and background microphone service.

It is not a good whole-repository fork: one contributor, no releases or CI, no iOS project, only three small Gemini-service tests, and a 10,361-line `translator_screen.dart`. It also carries a substantial unrelated OpenAI STT/TTS/assistant implementation. The useful approach is to reuse or port the Gemini service, directional-session logic, audio output, and focused tests under MIT attribution while rebuilding a small UI and key flow.

### 2. Strong architecture references, source not reusable without permission

These repositories had no license file at the review date, so their source should not be copied:

| Project | Useful idea | Mismatch |
|---|---|---|
| [sqrdao-intern/live-translator](https://github.com/sqrdao-intern/live-translator) | Installable mobile PWA, AudioWorklet→16 kHz PCM, two parallel Gemini translation sessions | Automatically routes by language, text-only output, uses a token server |
| [qscf11-png/live-translator](https://github.com/qscf11-png/live-translator) | Minimal client-only BYOK web app with direct Gemini connection | Subtitle-oriented, one-way/multi-target rather than manual A/B conversation |
| [marlonka/Dein-Babelfischi](https://github.com/marlonka/Dein-Babelfischi) | React/Vite microphone pipeline, PCM playback queue, transcript bubbles and replay | One target language with automatic source detection; local token backend |

### 3. Supporting references

- [Edwin1719/Google_Translate](https://github.com/Edwin1719/Google_Translate) (MIT) demonstrates bidirectional audio plus transcripts, but it is a Python/Flet desktop app and implements direction through prompting rather than native manual `translationConfig` sessions.
- [luoxiaoxin123/live-translate](https://github.com/luoxiaoxin123/live-translate) (Apache-2.0) is useful for Android capture/playback and key handling, but targets one-way subtitles/media translation.

### Updated recommendation

Keep `realtime-translation` as the clean product repository and use Flutter, with Android implemented first and iOS following on the same shared Dart core. Selectively port only justified Gemini/audio/directional pieces from `NA-DEGEN-GIRL/translator` with MIT attribution instead of inheriting its full UI and OpenAI surface.

## Focused review: official LiveKit and macOS references

### `google-gemini/gemini-live-translate-livekit`

[Repository](https://github.com/google-gemini/gemini-live-translate-livekit) — Apache-2.0.

This is the strongest reviewed reference for production-oriented Gemini Live Translate session behavior. Its useful patterns include:

- native `translationConfig` setup and a maintained language-code list;
- session-resumption handles and `goAway`-driven reconnect;
- serialized translated-audio publication so asynchronous buffers do not pile up;
- throttled interim transcripts and reliable final transcript delivery;
- setup timeouts and explicit per-language session ownership.

It should not be forked for this product. Its Next.js server, LiveKit room, media publication, and one-speaker-to-many-listeners model add a backend/media hop that a client-only, one-phone BYOK conversation does not need. Port only protocol/session ideas or small Apache-2.0 components with attribution, and adapt them to 16 kHz mobile microphone input, bounded local playback, redacted logs, and manual A/B direction selection.

### `kkdai/gemini-live-translate-macos`

[Repository](https://github.com/kkdai/gemini-live-translate-macos) — the README says MIT, but the reviewed repository has no `LICENSE` file and GitHub reports no asserted license. Treat its source as non-reusable unless the author adds a license or grants permission.

Its useful behavioral references are a serialized WebSocket lifecycle, a fresh `URLSession` on reconnect, stale-task callback guards, `AVAudioConverter` resampling, and `AVAudioEngine`/`AVAudioPlayerNode` PCM playback. It is not an iOS base: it captures application/system audio with macOS-only ScreenCaptureKit, stores the API key in `UserDefaults`, does not handle Gemini session-resumption handles, and lacks the iOS microphone, `AVAudioSession`, interruption, route-change, and Keychain behavior this product needs.

### Platform implication

Use Flutter for UI, language/direction state, Gemini protocol, transcript assembly, conversation history, and reconnect policy. Put microphone capture, PCM conversion/playback, audio focus/session lifecycle, device routing, and secure optional key persistence behind a typed platform interface. Implement Android first with Kotlin/Android audio APIs; preserve the contract and add the Swift/iOS implementation later.

## Official facts shaping the design

The current [Google Live Translation guide](https://ai.google.dev/gemini-api/docs/live-api/live-translate) documents:

- more than 70 supported languages;
- continuous low-latency translation rather than turn-based agent behavior;
- raw 16-bit little-endian PCM at 16 kHz mono for input and 24 kHz mono for output;
- a recommended 100 ms input chunk size;
- optional input and output transcripts;
- `translationConfig.targetLanguageCode` and `echoTargetLanguage`;
- constrained ephemeral tokens for client applications using the `v1beta` endpoint.

The same guide notes preview limitations around voice consistency, rapid language switching, accents, background audio, and echo artifacts. These are product risks to measure, not edge cases to postpone.

As of the survey date, [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing) listed an effective paid audio cost of approximately USD 0.0368 per minute for combined input and output at the documented token rates. Pricing and preview quotas can change and must be rechecked before release.
