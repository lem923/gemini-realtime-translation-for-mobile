# Changelog

All notable changes to realtime-translation will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- 逐句模式开始新一轮按住说话时，上一轮仍受原生背压阻塞的 drain 现在会
  立即停止消费；新一轮译音会一直缓冲到松手，避免旧 drain 提前播放。
- 同声传译停止后仍只播放一部分译音：模型以快于实时的速率生成音频，
  停止时积压可达十秒级，而收尾只等待固定的 3 秒。收尾等待时间现在按
  实际排队的剩余播放时长缩放（加上 5 秒余量，上限 30 秒），积压的
  译音能完整播完；链 settle 等待也复用同一上限而非固定 2 秒。

### Tests

- 新增逐句译音 FIFO/背压顺序、Dart 排队上限和跨轮 drain 竞态回归测试。

## [0.38.0] - 2026-08-14

### Fixed

- 逐句翻译译音卡顿：松开按钮后，模型仍在流式输出的尾部译音块此前直接
  无节流地塞进 Dart 播放链（最长一次排队近 6 秒），与缓冲播放并发导致
  原生队列补给出现间隙、播放卡顿。现在所有逐句译音（松手前缓冲 + 松手
  后尾音）统一走同一个串行消费队列，由原生背压自然限速，不再堆积在
  Dart 链上。

### Tests

- 128 Flutter tests pass; Android host tests and lint pass.

## [0.37.0] - 2026-08-14

### Changed

- 同声传译与讲座模式改为纯连续流式：说话结束不再发送 `audioStreamEnd`
  回合边界（此前 VAD 检测到 1 秒静音就强制模型收尾，最后几个单词被截断）。
  回合定稿交给服务端自动 VAD。
- 服务端自动 VAD 静音窗口从 500 ms 延长到 1000 ms，与客户端语音门控
  一致：服务端不再在用户话语中途抢先结束回合。

### Fixed

- 停止会话与回放译音的收尾现在等待 AudioTrack 内部缓冲排空后才释放
  播放器，回放（点击播放译文）不再丢失尾部。
- 停止收尾会持续接收模型尾音直到回合完成（最多 15 秒）而不是固定
  2 秒，模型仍在流式输出的长翻译不再被截断。

### Tests

- 127 Flutter tests pass; Android host tests and lint pass.

## [0.36.0] - 2026-08-14

### Fixed

- 译文尾部仍未完整播放：优雅收尾只等待了入队队列，没有计入已写入
  AudioTrack 内部缓冲、尚未播出的音频。原生指标现在报告
  `pendingPlaybackBytes`（队列字节 + 主/耳机轨已写入未播出的帧），停止
  收尾等待它归零后才释放播放器，最后几个单词不再被截断。
- 停止收尾的模型尾音宽限期从 1.5 秒延长到 2 秒。

### Tests

- 127 Flutter tests pass; Android host tests and lint pass.

## [0.35.0] - 2026-08-14

### Fixed

- 译文最后几个单词不播放（逐句/同声）：用户按停止时，排队的译音立即被
  丢弃。现在用户主动停止会进入有界优雅收尾：先停麦克风与会话边界，
  再接受模型最后一段译音（约 1.5 秒宽限），等 Dart 入队链与原生队列
  播完后才释放播放器（总时长有 2 秒上限，停止永远能完成）。模式切换、
  方向切换、权限撤销等内部停止仍立即切断。
- 播放失败自动恢复不再在会话已停止时重建播放器。

### Tests

- 126 Flutter tests pass; Android host tests and lint pass.

## [0.34.0] - 2026-08-14

### Fixed

- 译音全部无法播放（三个模式均受影响）：原生播放器的 enqueue 执行器在
  `dispose` 时被永久关闭，而 `configure` 每次都以 `dispose` 开头，导致第一次
  配置之后所有 `enqueue`/`enqueueTrack` 都抛 `RejectedExecutionException`，
  Dart 侧将其记为无原因的播放失败并静音整场会话。执行器现在在每次
  `dispose` 后重建，enqueue 任务也改为始终完成 MethodChannel 结果并携带
  错误消息。
- 诊断报告的 `模式` 字段现在记录会话运行时的模式，而不是打开报告时的
  当前模式（此前会把同声/讲座会话的数据显示为逐句翻译）。
- 所有 Dart 侧播放失败路径现在把具体异常写入诊断的 `播放错误` 原因，
  便于真机定位。

### Tests

- 124 Flutter tests pass; Android host tests and lint pass.

## [0.33.0] - 2026-08-14

### Changed

- 逐句翻译回退为纯 Live 会话路径：按住说话时，音频实时送入
  `gemini-3.5-live-translate-preview` 翻译，译文音频在本机缓冲；松开按钮后
  一次性播放本次译音。移除了独立 ASR 会话、REST 文本修正与系统 TTS 整条
  管线（`gemini-3.1-flash-live-preview` ASR 会话在真机被拒绝是逐句模式
  无法启动的根因）。删除 `语音自动修正` 开关与管线状态 UI。
- 修复 `_audioMuted` 跨会话残留：上一个会话的播放失败/系统中断会让之后
  每次新会话收到译文却不播放（诊断特征：`最大 Dart 排队: 0`、`播放错误: 0`、
  文字正常）。新会话现在总是从未静音开始。

### Tests

- 124 Flutter tests pass; Android host tests and lint pass.

## [0.32.0] - 2026-08-14

### Fixed

- 同声传译识别卡顿/逐句定稿失败：麦克风语音门控过严（进入阈值 64 倍噪声底、
  1.5 s 静音尾）会扣下轻声或语速略慢的整段语音，导致模型只收到残缺音频、
  回合无法定稿。进入阈值降为噪声底的 16 倍、静音尾缩短为 1 s。
- 诊断报告现在包含最近一次播放失败的原生原因与错误码，便于真机定位
  “译音播放失败”的根因，而不是只有失败计数。

### Tests

- 124 Flutter tests pass; Android host tests and lint pass.

## [0.31.0] - 2026-08-14

### Fixed

- Playback failure on real devices (同声传译/讲座): the native lanes now
  rebuild a fresh AudioTrack and retry the chunk once when the same-track
  retry fails, with a larger track buffer for HAL headroom. Dart additionally
  attempts one automatic playback reconfiguration after a failure instead of
  staying text-only.

### Tests

- 124 Flutter tests pass; Android host tests and lint pass.

## [0.30.0] - 2026-08-14

### Changed

- Removed the REST ASR fallback in 逐句翻译: the live ASR session
  (gemini-3.1-flash-live-preview) is the only audio path. Verified that the
  flash/pro families reject inline audio in REST generateContent and that
  gemini-2.5-pro hallucinates transcripts, so a wrong fallback is worse than
  an explicit error: on session rejection the user gets a clear message and
  can retry.

### Tests

- 124 Flutter tests pass; Android host tests and lint pass.

## [0.29.0] - 2026-08-14

### Fixed

- 逐句翻译 ASR rejection: the live ASR session now uses a minimal
  transcription-only setup (no context compression / VAD config fields that
  some live models reject), and when the live session is rejected or not
  ready, the pipeline falls back to the REST ASR (gemini-2.5-pro, inline
  audio) using the buffered recording. The recording is always kept locally
  as the fallback source.
- Simultaneous/lecture playback failure: native playback now retries the
  track once (pause/flush/play + rewrite) before reporting a failure, which
  recovers transient route/focus-related track errors instead of dropping to
  text-only.
- Switching conversation modes now always stops an active conversation, and
  the bottom button returns to 开始翻译 in the idle state.

### Tests

- 124 Flutter tests pass; Android host tests and lint pass.

## [0.28.0] - 2026-08-14

### Changed

- 逐句翻译 now streams PCM to the ASR session (gemini-3.1-flash-live-preview)
  while the push-to-talk button is held instead of recording locally and
  transcribing after release. The session connects at conversation start; the
  first ~2 s pre-ready window is buffered and flushed once the session is up.
  On release the transcript is already settled, so the remaining work is the
  text correction (gemini-flash-lite-latest) and TTS playback.

### Tests

- 124 Flutter tests pass, including streaming push-to-talk, buffer-flush,
  and pipeline regressions; Android host tests and lint pass.

## [0.27.0] - 2026-08-14

### Changed

- 逐句翻译 ASR now uses the audio-native Gemini 3.1 Flash Live model
  (`gemini-3.1-flash-live-preview`) over the Live API: flash-class cost and
  verified Chinese transcription quality. The correction+translation step
  uses `gemini-flash-lite-latest`. The transcription settles dynamically
  (no fixed wait), and the full pipeline (ASR → correct+translate → TTS)
  runs in about 11 s for a sentence.
- Flash-family models still reject inline audio via REST generateContent, so
  the audio path stays on the Live API; this is documented in the probe tools.

### Tests

- 124 Flutter tests pass; Android host tests and lint pass. New probe tools:
  `tool/live_asr_probe.dart` and `tool/sentence_pipeline_probe.dart` (real-API
  verification of the exact pipeline used in the app).

## [0.26.0] - 2026-08-14

### Changed

- 逐句翻译 is now push-to-talk only (微信式): press and hold to record, release
  ends the sentence. Recording is fully local, so the button responds
  immediately even before any network connect; pressing cuts any playing
  translation.
- 逐句翻译 no longer uses the Live Translate session. After release the app
  runs an offline-style pipeline: ASR (gemini-2.5-pro, verified to accept
  inline audio; flash-class models currently drop inline audio) → correct +
  translate with the last 10 minutes of context (gemini-2.5-flash-lite) →
  system TTS synthesized to the existing playback engine. The 语音自动修正
  toggle controls the correction step. This also frees a Live session/quota.
- The pipeline status (识别中/修正翻译中/合成播放中) is shown in the dock;
  failures fall back to showing the error without blocking the app.

### Tests

- 124 Flutter tests pass, including push-to-talk buffering, context passing,
  pipeline failure fallback, and mode regressions; Android host tests and
  lint pass.

## [0.25.0] - 2026-08-14

### Changed

- Playback no longer stutters: the native lanes now apply real backpressure
  (enqueue blocks until the audio is consumed instead of dropping chunks or
  pacing from Dart), so every mode streams smoothly, including replay.
- 耳机分离 mode was replaced by 讲座模式 (lecture mode): the user picks the
  source language, the target language, and the microphone channel (built-in
  or headset). Speech on the selected channel is translated into the
  user's headset in real time; the phone speaker is not used. The UI shows a
  dedicated config panel instead of the A/B speaker cards.
- 逐句翻译 playback now starts only at the client's own utterance
  finalization, not at the server's earlier turn-complete, so buffered
  translations no longer leak out while the speaker continues.

### Tests

- 124 Flutter tests pass, including lecture routing, channel selection, and
  buffered-playback regressions; Android host tests and lint pass.

## [0.24.0] - 2026-08-14

### Changed

- 耳机分离 mode now binds the sides explicitly: 机主 (left) uses the headset
  mic with translations played on the phone speaker, 对方 (right) uses the
  built-in mic with translations played on the headset. The speaker lane is
  forced to the builtin speaker; when the platform cannot split playback
  (Bluetooth SCO keeps routing into the headset), the wearer's own
  translation is no longer played into the headset and the other person
  reads it from the screen (lecture fallback), with a clear hint.
- 逐句翻译 now buffers translated audio while the speaker is talking and
  starts playback only after the sentence finalizes, so the user no longer
  hears the translation while speaking; long sentences are no longer
  interrupted by the echo guard.
- Every utterance end now sends `audioStreamEnd` in all modes, so the server
  flushes its cached final translation and the last words no longer go
  missing in 同声传译.

### Tests

- 123 Flutter tests pass; Android host tests and lint pass.

## [0.23.2] - 2026-08-14

### Fixed

- Fixed the 耳机分离 crash identified by the on-device crash log: the headset
  capture thread emitted EventChannel events from a background thread, which
  the Flutter embedding rejects with a UiThread RuntimeException. Events are
  now dispatched on the platform main thread.

### Tests

- 123 Flutter tests pass; Android host tests and lint pass.

## [0.23.1] - 2026-08-14

### Fixed

- 耳机分离 mode could crash the app on devices with audio HALs that reject
  voice-communication tracks for Bluetooth music (A2DP) devices. The headset
  playback lane is now created lazily and defensively, A2DP outputs are
  excluded, and every native audio step fails closed instead of throwing.
- Uncaught Dart errors no longer kill the app: they are captured in a bounded
  local crash log alongside native crashes.

### Added

- The diagnostics report now includes the recent local crash log (exported
  only when the user copies the report).

### Tests

- 123 Flutter tests pass; Android host tests and lint pass.

## [0.23.0] - 2026-08-13

### Added

- 耳机分离 conversation mode: with a microphone-equipped headset connected,
  the headset mic captures the wearer (speaker A) while the built-in mic
  captures the other person (speaker B). Direction switches automatically on
  detected speech; A's translation plays on the phone speaker and B's
  translation plays on the headset. Fails closed with a clear message when no
  headset is available. Manual direction selection remains unchanged in the
  other two modes.
- Sentence-by-sentence finalization now requires a 1.5 s silence tail before
  an utterance is considered finished.
- Diagnostics report automatic direction switches and headset state.

### Changed

- Context-window compression A/B verified against the real Live API: the
  AI Studio examples' `triggerTokens: 0` / `targetTokens: 0` config is
  accepted and behaves identically to the current empty sliding-window
  config (zeros mean "unset" server-side), so the production setup is
  unchanged. The probe tool is included for future experiments.

### Tests

- 123 Flutter tests pass, including headset fail-closed, auto-direction,
  per-track playback routing, and 1.5 s-finalization regressions; Android
  host tests and lint pass. On-device runs verified the three-way mode
  selector and the no-headset fail-closed hint.

## [0.22.0] - 2026-08-13

### Added

- Conversation modes: 逐句翻译 (sentence-by-sentence) keeps the echo guard
  and finalizes each utterance; 同声传译 (simultaneous) keeps the microphone
  open while translated audio plays, matching the AI Studio live-playground
  flow, and is recommended for earpiece/headset use. A segmented selector with
  per-mode guidance sits under the status strip in both layouts.

### Changed

- Sustained speech during translated playback now barges in: the translation
  playback is cut, the microphone reopens, and the new utterance is forwarded
  immediately. Diagnostics report 抢话中断 events.
- Diagnostics include the active conversation mode.

### Tests

- 120 Flutter tests pass, including barge-in, simultaneous-mode routing, and
  mode-selector regressions; Android host tests and lint pass. On-device runs
  confirmed the mode selector, simultaneous-mode diagnostics, and a healthy
  real-Gemini session.

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
